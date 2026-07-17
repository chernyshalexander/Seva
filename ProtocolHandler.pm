package Plugins::Seva::ProtocolHandler;

use strict;
use utf8;
use base qw(Slim::Player::Protocols::HTTPS);

use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;
use IO::Select;
use URI::Escape qw(uri_unescape);
use Encode qw(decode);

my $log = logger('plugin.seva');

# Constructor override: feed the resolved streamUrl to the parent constructor
# so the underlying HTTPS transport socket connects to the real HTTPS URL instead of seva://
sub new {
    my $class = shift;
    my $args  = shift;
    
    my $client = $args->{client};
    my $song   = $args->{song};
    
    # Retrieve the resolved HTTPS stream URL that we set in getNextTrack
    my $streamUrl = $song->streamUrl() || return;
    
    $log->info("ProtocolHandler new: connecting to resolved streamUrl: $streamUrl");
    
    my $prefs = Slim::Utils::Prefs::preferences('plugin.seva');
    if ($prefs->get('use_proxy')) {
        my $proxy_addr = $prefs->get('proxy_address');
        my $proxy_port = $prefs->get('proxy_port');
        my $proxy_user = $prefs->get('proxy_username');
        my $proxy_pass = $prefs->get('proxy_password');
        
        my ($server, $port, $path) = Slim::Utils::Misc::crackURL($streamUrl);
        my $insecure = Slim::Utils::Prefs::preferences('server')->get('insecureHTTPS') || 0;
        my $timeout = $args->{timeout} || Slim::Utils::Prefs::preferences('server')->get('remotestreamtimeout') || 10;
        
        $log->info("ProtocolHandler new intercept: connecting to $server:$port via HTTP proxy $proxy_addr:$proxy_port");
        
        my $sock = Plugins::Seva::Plugin::connect_via_proxy(
            'http', $proxy_addr, $proxy_port, $proxy_user, $proxy_pass,
            $server, $port, 1, $timeout, $insecure
        );
        
        if (!$sock) {
            $log->error("ProtocolHandler new intercept: proxy connection failed");
            return undef;
        }
        
        # Bless into the ProtocolHandler class
        bless $sock, $class;
        
        # Set the required metadata fields expected by Slim::Player::Protocols::HTTP / HTTPS
        ${*$sock}{'client'}  = $client;
        ${*$sock}{'url'}     = $streamUrl;
        ${*$sock}{'song'}    = $song;
        ${*$sock}{'_sel'}    = IO::Select->new($sock);
        
        # Call open ($sock->open is Slim::Player::Protocols::HTTP::open)
        return $sock->open($args);
    }
    
    my $sock = $class->SUPER::new({
        url    => $streamUrl,
        song   => $song,
        client => $client,
    }) || return;
    
    return $sock;
}

sub scanUrl {
    my ($class, $url, $args) = @_;
    $log->info("scanUrl called for URL: $url");
    
    my $sevaTrack = $args->{song}->currentTrack();
    if ($sevaTrack && $url =~ /\.mp3/i) {
        # Retrieve the exact bitrate from the URL parameter
        my $bitrate = 128000;
        if ($url =~ /[?&]bitrate=(\d+)/) {
            $bitrate = $1;
        }
        $log->info("scanUrl: archive track detected. Setting bitrate=$bitrate");
        $sevaTrack->bitrate($bitrate);
        $sevaTrack->content_type('mp3');
        Slim::Music::Info::setBitrate($url, $bitrate);
    }
    
    $args->{cb}->( $args->{song}->currentTrack() );
}

sub getNextTrack {
    my ($class, $song, $successCb, $errorCb) = @_;
    
    my $url = $song->currentTrack()->url;
    $log->info("getNextTrack called for URL: $url");
    
    # Unwrap seva:// to https://
    my $real_url = $url;
    $real_url =~ s|^seva://||;
    $real_url =~ s|\?.*$||;
    $real_url = "https://" . $real_url;
    
    $log->info("getNextTrack: resolved seva:// stream to real URL: $real_url");
    
    $song->streamUrl($real_url);
    $successCb->();
}

sub getMetadataFor {
    my ($class, $client, $url) = @_;
    
    # Parse title and album from the query parameters in the seva:// URL
    my $title = 'Radio Seva';
    my $album = 'Radio Seva';
    my $bitrate = 128000;
    
    if ($url =~ /[?&]title=([^&]+)/) {
        $title = uri_unescape($1);
        $title = decode('utf-8', $title);
    }
    if ($url =~ /[?&]album=([^&]+)/) {
        $album = uri_unescape($1);
        $album = decode('utf-8', $album);
    }
    if ($url =~ /[?&]bitrate=(\d+)/) {
        $bitrate = $1;
    }
    
    # Retrieve the dynamically updated cover from client data
    my $cover = $client ? $client->pluginData('seva_cover_url') : undef;
    $cover ||= 'plugins/Seva/html/images/radio.png';
    
    my $artist = string('PLUGIN_SEVA_ARTIST');
    my $duration = Slim::Music::Info::getDuration($url);
    my $bitrate_str = sprintf("%.0fkbps", $bitrate / 1000);
    
    $log->info("getMetadataFor: URL='$url' -> title='$title', artist='$artist', album='$album', cover='$cover', duration=" . ($duration || 'none'));
    
    my $meta = {
        title    => $title,
        artist   => $artist,
        album    => $album,
        cover    => $cover,
        icon     => 'plugins/Seva/html/images/radio.png',
        bitrate  => $bitrate_str,
        type     => 'mp3',
        isRemote => 1,
    };
    
    if ($duration) {
        $meta->{duration} = $duration;
    }
    
    return $meta;
}

# Intercept parsed headers to set duration/bitrate for archive tracks
sub parseHeaders {
    my $self = shift;
    
    # Let the parent parse headers first (sets contentLength, etc.)
    $self->SUPER::parseHeaders(@_);
    
    my $song = ${*$self}{'song'};
    if ($song) {
        my $url = $song->currentTrack()->url;
        
        # Only perform calculation for archive tracks (containing .mp3 in URL)
        if ($url =~ /\.mp3/i) {
            my $length = ${*$self}{'contentLength'};
            if ($length && $length > 0) {
                # Retrieve the exact bitrate from the URL parameter
                my $bitrate = 128000;
                if ($url =~ /[?&]bitrate=(\d+)/) {
                    $bitrate = $1;
                }
                
                my $duration = int($length * 8 / $bitrate);
                
                $log->info("parseHeaders: archive track detected. Length=$length bytes. Bitrate=$bitrate bps, duration=$duration seconds");
                
                ${*$self}{'bitrate'} = $bitrate;
                $song->bitrate($bitrate);
                $song->duration($duration);
                $song->isLive(0);
                
                Slim::Music::Info::setBitrate($url, $bitrate);
                Slim::Music::Info::setDuration($url, $duration);
                
                # Update progress bar for the client
                my $client = $self->client;
                if ($client) {
                    $client->streamingProgressBar({
                        'url'      => $url,
                        'duration' => $duration,
                    });
                }
            }
        }
    }
}

# Determine seek support: enabled for archive tracks with duration, disabled for live stream
sub canSeek {
    my ($class, $client, $song) = @_;
    my $url = $song->currentTrack()->url;
    
    if ($url =~ /\.mp3/i) {
        $log->info("canSeek: archive track seek support=1");
        return 1;
    }
    
    $log->info("canSeek: live stream seek support=0");
    return 0;
}

# Explicitly declare that seva:// URLs resolve to mp3 format
sub getFormatForURL {
    my ($class, $url) = @_;
    $log->info("getFormatForURL called for URL: " . ($url || 'none'));
    return 'mp3';
}

sub formatOverride {
    my ($class, $song) = @_;
    $log->info("formatOverride called");
    return 'mp3';
}

sub isRemote { 1 }
sub isAudio { 1 }

# Force proxy playback through LMS so we can intercept and provide custom stream data
sub canDirectStream { return 0; }

1;
