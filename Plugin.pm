package Plugins::Seva::Plugin;

use strict;
use utf8;
use File::Spec;
use Slim::Networking::SimpleAsyncHTTP;
use Slim::Player::ProtocolHandlers;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Utils::Prefs;
use Time::HiRes;
use base qw(Slim::Plugin::OPMLBased);
use Encode qw(decode);

use Plugins::Seva::ProtocolHandler;

our $pluginDir;
my $log;
my $prefs;

BEGIN {
    $pluginDir = $INC{"Plugins/Seva/Plugin.pm"};
    $pluginDir =~ s/Plugin.pm$//; 
}

# Initialize logging
$log = Slim::Utils::Log->addLogCategory({
    'category'     => 'plugin.seva',
    'defaultLevel' => 'INFO',
    'description'  => string('PLUGIN_SEVA'),
});

$prefs = preferences('plugin.seva');

sub initPlugin {
    my $class = shift;
    
    $log->info("SEVA INIT: Starting Plugin initialization...");
    
    Slim::Utils::Strings::loadFile(File::Spec->catfile($pluginDir, 'strings.txt'));
    
    # Initialize preferences
    $prefs->init({
        demostrate_photos => 1,
        photo_interval => 180,
        use_proxy => 0,
        proxy_address => '',
        proxy_port => '',
        proxy_username => '',
        proxy_password => '',
    });
    
    # Listen to changes in settings
    $prefs->setChange(\&_on_pref_change, 'demostrate_photos');
    
    # Register settings UI
    if (main::WEBUI) {
        require Plugins::Seva::Settings;
        Plugins::Seva::Settings->new();
        $log->info("SEVA INIT: Settings UI registered.");
    }
    
    # Register seva:// protocol handler
    Slim::Player::ProtocolHandlers->registerHandler('seva', 'Plugins::Seva::ProtocolHandler');
    $log->info("SEVA INIT: seva:// ProtocolHandler registered.");
    
    # Apply monkeypatch to route SimpleAsyncHTTP calls to seva.ru through HTTP proxy if configured
    _patch_async_http_new_socket();
    
    # Subscribe to player events (newsong, play, pause, stop, clear)
    Slim::Control::Request::subscribe(
        \&playerEventCallback,
        [['playlist', 'mixer', 'play', 'pause'], ['newsong', 'jump', 'stop', 'clear', 'pause', 'client']]
    );
    $log->info("SEVA INIT: Subscribed to LMS player events.");
    
    $class->SUPER::initPlugin(
        feed   => \&_feedHandler,
        tag    => 'seva',
        menu   => 'radios',
        is_app => 1,
        weight => 10,
    );
    
    $log->info("SEVA INIT: initPlugin completed successfully.");
}

sub getDisplayName { 'PLUGIN_SEVA' }

sub isRemote { 1 }

sub shutdownPlugin {
    my $class = shift;
    
    $log->info("SEVA SHUTDOWN: Cleaning up plugin...");
    Slim::Control::Request::unsubscribe(\&playerEventCallback);
    
    # Clean up all timers on shutdown
    for my $client (Slim::Player::Client::clients()) {
        _cancelPhotoTimer($client);
    }
}

sub _makeSevaUrl {
    my ($real_url, $title, $album, $bitrate) = @_;
    # strip https:// or http://
    my $path = $real_url;
    $path =~ s|^https?://||i;
    
    require URI::Escape;
    my $esc_title = URI::Escape::uri_escape_utf8($title || '');
    my $esc_album = URI::Escape::uri_escape_utf8($album || '');
    
    my $seva_url = "seva://" . $path . "?title=" . $esc_title . "&album=" . $esc_album;
    if ($bitrate) {
        $seva_url .= "&bitrate=" . $bitrate;
    }
    
    $log->info("Formatting Seva URL: $real_url -> $seva_url");
    return $seva_url;
}

sub _feedHandler {
    my ($client, $callback, $args) = @_;
    
    my $menu = [
        {
            name  => string('PLUGIN_SEVA_LIVE'),
            type  => 'audio',
            url   => _makeSevaUrl('https://seva.ru/radio/stream', string('PLUGIN_SEVA_LIVE'), string('PLUGIN_SEVA_LIVE'), 128000),
            image => 'plugins/Seva/html/images/radio.png',
        },
        {
            name  => string('PLUGIN_SEVA_ROCK'),
            type  => 'link',
            url   => \&_rockYearsHandler,
            image => 'html/images/musicfolder.png',
        },
        {
            name  => string('PLUGIN_SEVA_OBOROT'),
            type  => 'link',
            url   => \&_oborotYearsHandler,
            image => 'html/images/musicfolder.png',
        }
    ];
    
    $callback->({
        items => $menu
    });
}

sub _rockYearsHandler {
    my ($client, $callback, $args) = @_;
    $log->info("Fetching rock archive years from seva.ru");
    
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $html = $http->content;
            $html = decode('cp1251', $html);
            
            my %years;
            while ($html =~ /href="[^"]*y=(\d{4})"/gi) {
                $years{$1} = 1;
            }
            
            my @items;
            for my $year (sort { $b <=> $a } keys %years) {
                push @items, {
                    name => $year,
                    type => 'link',
                    url => \&_rockEpisodesHandler,
                    passthrough => [ $year ],
                };
            }
            
            $log->info("Parsed " . scalar(@items) . " rock archive years.");
            $callback->({ items => \@items });
        },
        sub {
            my $http = shift;
            $log->error("Failed to fetch rock years: " . $http->error);
            $callback->({ items => [{ name => "Error loading years", type => 'text' }] });
        }
    )->get('https://seva.ru/rock/');
}

sub _rockEpisodesHandler {
    my ($client, $callback, $args, $year) = @_;
    $log->info("Fetching rock archive episodes for year $year");
    
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $html = $http->content;
            $html = decode('cp1251', $html);
            
            my @items;
            while ($html =~ /<tr\s+id="a\d+">(.*?)<\/tr>/gs) {
                my $row = $1;
                if ($row =~ /<td><b>(\d{2}\.\d{2}\.\d{4})<\/b><\/td>/s) {
                    my $date = $1;
                    
                    my @tds;
                    while ($row =~ /<td.*?>(.*?)<\/td>/gs) {
                        push @tds, $1;
                    }
                    
                    my $title = "";
                    if (@tds >= 2) {
                        $title = $tds[1];
                        $title =~ s/<[^>]+>//g;
                        $title =~ s/^\s+|\s+$//g;
                    }
                    
                    my $url = "";
                    my $bitrate = 128000; # fallback default
                    
                    if ($row =~ /<a\s+href="([^"]+\.mp3)"[^>]*>(.*?)<\/a>/is) {
                        $url = $1;
                        my $link_content = $2;
                        if ($link_content =~ /alt="([^"]*?MP3\s+(\d+)\s*kbps[^"]*)"/is) {
                            $bitrate = $2 * 1000;
                            $log->info("Parsed rock episode bitrate: $bitrate bps from alt='$1'");
                        }
                    } elsif ($row =~ /<a\s+href="([^"]+\.mp3)"/s) {
                        $url = $1;
                    }
                    
                    if ($url) {
                        my $mp3_url = $url;
                        if ($mp3_url =~ s/^\.\.\/\.\.\//https:\/\/seva.ru\//) {
                            # ok
                        } elsif ($mp3_url =~ s/^\.\.\//https:\/\/seva.ru\//) {
                            # ok
                        } elsif ($mp3_url =~ s/^\//https:\/\/seva.ru\//) {
                            # ok
                        } else {
                            $mp3_url = "https://seva.ru/rock/" . $mp3_url;
                        }
                        
                        my $seva_url = _makeSevaUrl($mp3_url, $title, string('PLUGIN_SEVA_ROCK'), $bitrate);
                        push @items, {
                            name   => "$date - $title",
                            title  => $title,
                            type   => 'audio',
                            url    => $seva_url,
                            artist => string('PLUGIN_SEVA_ARTIST'),
                            album  => string('PLUGIN_SEVA_ROCK'),
                        };
                    }
                }
            }
            
            $log->info("Parsed " . scalar(@items) . " rock episodes for year $year.");
            $callback->({ items => \@items });
        },
        sub {
            my $http = shift;
            $log->error("Failed to fetch rock episodes for year $year: " . $http->error);
            $callback->({ items => [{ name => "Error loading episodes", type => 'text' }] });
        }
    )->get("https://seva.ru/rock/?y=$year");
}

sub _oborotYearsHandler {
    my ($client, $callback, $args) = @_;
    $log->info("Fetching oborot archive years from seva.ru");
    
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $html = $http->content;
            $html = decode('cp1251', $html);
            
            my %years;
            while ($html =~ /href="[^"]*y=(\d{4})"/gi) {
                $years{$1} = 1;
            }
            
            my @items;
            for my $year (sort { $b <=> $a } keys %years) {
                push @items, {
                    name => $year,
                    type => 'link',
                    url => \&_oborotEpisodesHandler,
                    passthrough => [ $year ],
                };
            }
            
            $log->info("Parsed " . scalar(@items) . " oborot archive years.");
            $callback->({ items => \@items });
        },
        sub {
            my $http = shift;
            $log->error("Failed to fetch oborot years: " . $http->error);
            $callback->({ items => [{ name => "Error loading years", type => 'text' }] });
        }
    )->get('https://seva.ru/oborot/');
}

sub _oborotEpisodesHandler {
    my ($client, $callback, $args, $year) = @_;
    $log->info("Fetching oborot archive episodes for year $year");
    
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $html = $http->content;
            $html = decode('cp1251', $html);
            
            my @items;
            while ($html =~ /<tr\s+id="a\d+">(.*?)<\/tr>/gs) {
                my $row = $1;
                if ($row =~ /<td><b>(\d{2}\.\d{2}\.\d{4})<\/b><\/td>/s) {
                    my $date = $1;
                    
                    my @tds;
                    while ($row =~ /<td.*?>(.*?)<\/td>/gs) {
                        push @tds, $1;
                    }
                    
                    my $title = "";
                    if (@tds >= 3) {
                        $title = $tds[2];
                        my $guest_info = "";
                        if ($title =~ /<div class="oborot-guest">(.*?)<\/div>/s) {
                            $guest_info = $1;
                            $guest_info =~ s/<[^>]+>//g;
                            $guest_info =~ s/^\s+|\s+$//g;
                            $guest_info =~ s/^Гости:\s*//i;
                            $title =~ s/<div class="oborot-guest">.*?<\/div>//gs;
                        }
                        $title =~ s/<[^>]+>//g;
                        $title =~ s/^\s+|\s+$//g;
                        
                        if ($guest_info) {
                            $title .= " (Гости: $guest_info)";
                        }
                    }
                    
                    my $url = "";
                    my $bitrate = 128000; # fallback default
                    
                    if ($row =~ /<a\s+href="([^"]+\.mp3)"[^>]*>(.*?)<\/a>/is) {
                        $url = $1;
                        my $link_content = $2;
                        if ($link_content =~ /alt="([^"]*?MP3\s+(\d+)\s*kbps[^"]*)"/is) {
                            $bitrate = $2 * 1000;
                            $log->info("Parsed oborot episode bitrate: $bitrate bps from alt='$1'");
                        }
                    } elsif ($row =~ /<a\s+href="([^"]+\.mp3)"/s) {
                        $url = $1;
                    }
                    
                    if ($url) {
                        my $mp3_url = $url;
                        if ($mp3_url =~ s/^\.\.\/\.\.\//https:\/\/seva.ru\//) {
                            # ok
                        } elsif ($mp3_url =~ s/^\.\.\//https:\/\/seva.ru\//) {
                            # ok
                        } elsif ($mp3_url =~ s/^\//https:\/\/seva.ru\//) {
                            # ok
                        } else {
                            $mp3_url = "https://seva.ru/oborot/archive/" . $mp3_url;
                        }
                        
                        my $seva_url = _makeSevaUrl($mp3_url, $title, string('PLUGIN_SEVA_OBOROT'), $bitrate);
                        push @items, {
                            name   => "$date - $title",
                            title  => $title,
                            type   => 'audio',
                            url    => $seva_url,
                            artist => string('PLUGIN_SEVA_ARTIST'),
                            album  => string('PLUGIN_SEVA_OBOROT'),
                        };
                    }
                }
            }
            
            $log->info("Parsed " . scalar(@items) . " oborot episodes for year $year.");
            $callback->({ items => \@items });
        },
        sub {
            my $http = shift;
            $log->error("Failed to fetch oborot episodes for year $year: " . $http->error);
            $callback->({ items => [{ name => "Error loading episodes", type => 'text' }] });
        }
    )->get("https://seva.ru/oborot/archive/?y=$year");
}

sub playerEventCallback {
    my $request = shift;
    my $client  = $request->client() || return;
    my $command = $request->getRequest(1);
    
    # Sync checking
    if ($client->isSynced() && !Slim::Player::Sync::isMaster($client)) {
        return;
    }
    
    my $song = $client->playingSong();
    my $track_url = ($song && $song->track()) ? $song->track()->url() : '';
    
    $log->info("playerEventCallback: player='" . $client->name() . "' command='$command' url='" . ($track_url || 'none') . "'");
    
    if ($command eq 'newsong') {
        if ($track_url =~ /^seva:\/\//) {
            $log->info("playerEventCallback: [newsong] Seva track detected. Fetching cover and scheduling timer...");
            # Fetch immediately
            _fetchNewPhoto($client, sub {
                my ($cover_url) = @_;
                if ($cover_url) {
                    $log->info("playerEventCallback: [newsong] Fetched cover URL: $cover_url");
                    $client->pluginData('seva_cover_url', $cover_url);
                    Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
                } else {
                    $log->warn("playerEventCallback: [newsong] Cover fetch returned empty.");
                }
                _schedulePhotoTimer($client);
            });
        } else {
            $log->info("playerEventCallback: [newsong] Non-Seva track detected. Cleaning up...");
            _cancelPhotoTimer($client);
            $client->pluginData('seva_cover_url', undef);
        }
    }
    elsif ($command eq 'play') {
        if ($track_url =~ /^seva:\/\//) {
            $log->info("playerEventCallback: [play] Seva stream resumes. Scheduling timer...");
            _schedulePhotoTimer($client);
        }
    }
    elsif ($command eq 'pause') {
        if ($track_url =~ /^seva:\/\//) {
            if ($client->isPaused()) {
                $log->info("playerEventCallback: [pause] Seva stream paused. Cancelling timer...");
                _cancelPhotoTimer($client);
            } else {
                $log->info("playerEventCallback: [pause] Seva stream unpaused. Scheduling timer...");
                _schedulePhotoTimer($client);
            }
        }
    }
    elsif ($command eq 'stop' || $command eq 'clear') {
        $log->info("playerEventCallback: [$command] Stopping. Cancelling timer...");
        _cancelPhotoTimer($client);
        $client->pluginData('seva_cover_url', undef);
    }
}

sub _schedulePhotoTimer {
    my ($client) = @_;
    
    _cancelPhotoTimer($client);
    
    my $enabled = $prefs->get('demostrate_photos');
    $log->info("_schedulePhotoTimer: player='" . $client->name() . "' enabled=" . ($enabled ? 1 : 0));
    
    return unless $enabled;
    
    my $interval = int($prefs->get('photo_interval') || 180);
    $log->info("_schedulePhotoTimer: scheduling EV timer in $interval seconds for player=" . $client->name());
    
    Slim::Utils::Timers::setTimer(
        $client,
        Time::HiRes::time() + $interval,
        \&_photoTimerCallback,
        $client
    );
}

sub _cancelPhotoTimer {
    my ($client) = @_;
    $log->info("_cancelPhotoTimer: player='" . $client->name() . "'");
    Slim::Utils::Timers::killTimers($client, \&_photoTimerCallback);
}

sub _photoTimerCallback {
    my ($client) = @_;
    
    my $song = $client->playingSong();
    my $track_url = ($song && $song->track()) ? $song->track()->url() : '';
    
    $log->info("_photoTimerCallback fired: player='" . $client->name() . "' url='$track_url'");
    
    if ($track_url =~ /^seva:\/\//) {
        _fetchNewPhoto($client, sub {
            my ($cover_url) = @_;
            if ($cover_url) {
                $log->info("_photoTimerCallback: updated cover URL to: $cover_url");
                $client->pluginData('seva_cover_url', $cover_url);
                Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
            }
            _schedulePhotoTimer($client);
        });
    } else {
        $log->info("_photoTimerCallback: player '" . $client->name() . "' is no longer playing Seva. Stopping timer loop.");
    }
}

sub _fetchNewPhoto {
    my ($client, $cb) = @_;
    
    my $ts = time();
    $log->info("_fetchNewPhoto: fetching main page https://seva.ru/?_=$ts");
    
    Slim::Networking::SimpleAsyncHTTP->new(
        sub {
            my $http = shift;
            my $html = $http->content;
            $html = decode('cp1251', $html);
            
            $log->info("_fetchNewPhoto: page fetched, HTML size=" . length($html) . " characters.");
            
            # parse photo block from main page
            if ($html =~ /<img\s+src="(\.\/photo_pics\/[^"]+)"/i) {
                my $src = $1;
                $src =~ s|^\./||;
                my $img_url = "https://seva.ru/" . $src;
                
                # Replace the thumbnail suffix "s" with large image if possible
                my $large_url = $img_url;
                if ($large_url =~ s/s\.jpg$/\.jpg/i) {
                    $log->info("_fetchNewPhoto: parsed thumbnail=$img_url -> resolved large_url=$large_url");
                    $cb->($large_url);
                } else {
                    $log->info("_fetchNewPhoto: parsed photo=$img_url (no thumbnail suffix found)");
                    $cb->($img_url);
                }
            } else {
                $log->error("_fetchNewPhoto: Failed to locate photo image block in main page HTML!");
                $cb->(undef);
            }
        },
        sub {
            my $http = shift;
            $log->error("_fetchNewPhoto: HTTP request failed: " . $http->error);
            $cb->(undef);
        }
    )->get("https://seva.ru/?_=$ts");
}

sub _on_pref_change {
    my ($pref, $new_value, $client) = @_;
    $log->info("_on_pref_change: $pref changed to $new_value");
    
    if ($client) {
        if (!$new_value) {
            _cancelPhotoTimer($client);
            $client->pluginData('seva_cover_url', undef);
            Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
        } else {
            _schedulePhotoTimer($client);
        }
    } else {
        for my $c (Slim::Player::Client::clients()) {
            if (!$new_value) {
                _cancelPhotoTimer($c);
                $c->pluginData('seva_cover_url', undef);
                Slim::Control::Request::notifyFromArray($c, ['newmetadata']);
            } else {
                _schedulePhotoTimer($c);
            }
        }
    }
}

sub connect_via_proxy {
    my ($proxy_type, $proxy_addr, $proxy_port, $proxy_user, $proxy_pass, $dest_host, $dest_port, $is_https, $timeout, $insecure_https) = @_;
    
    $timeout ||= 10;
    
    $log->info("connect_via_proxy: connecting to proxy $proxy_addr:$proxy_port");
    
    require IO::Socket::INET;
    my $sock = IO::Socket::INET->new(
        PeerAddr => $proxy_addr,
        PeerPort => $proxy_port,
        Timeout  => $timeout,
    );
    
    if (!$sock) {
        $log->error("connect_via_proxy: TCP connection to proxy $proxy_addr:$proxy_port failed: $!");
        return undef;
    }
    
    # Establish tunnel using CONNECT method
    my $connect_req = "CONNECT $dest_host:$dest_port HTTP/1.1\r\n"
                    . "Host: $dest_host:$dest_port\r\n";
    
    if ($proxy_user) {
        require MIME::Base64;
        my $auth = MIME::Base64::encode_base64("$proxy_user:$proxy_pass", "");
        $connect_req .= "Proxy-Authorization: Basic $auth\r\n";
    }
    $connect_req .= "\r\n";
    
    $sock->syswrite($connect_req);
    
    # Read response headers
    my $response = '';
    my $buf = '';
    while (1) {
        my $n = $sock->sysread($buf, 1);
        last if !$n;
        $response .= $buf;
        last if $response =~ /\r\n\r\n$/;
    }
    
    if ($response !~ /^HTTP\/1\.[01]\s+200/) {
        $log->error("connect_via_proxy: proxy tunnel establishment failed:\n$response");
        $sock->close();
        return undef;
    }
    
    $log->info("connect_via_proxy: proxy tunnel established successfully to $dest_host:$dest_port");
    
    # If HTTPS, wrap socket with SSL
    if ($is_https) {
        require IO::Socket::SSL;
        
        my %ssl_args = (
            SSL_hostname => $dest_host,
        );
        if ($insecure_https) {
            $ssl_args{SSL_verify_mode} = 0; # SSL_VERIFY_NONE
        }
        
        $sock = IO::Socket::SSL->start_SSL($sock, %ssl_args);
        if (!$sock) {
            $log->error("connect_via_proxy: SSL handshake over HTTP proxy failed: " . IO::Socket::SSL->errstr());
            return undef;
        }
        $log->info("connect_via_proxy: SSL handshake over HTTP proxy completed successfully");
    }
    
    return $sock;
}

sub _patch_async_http_new_socket {
    require Slim::Networking::Async::HTTP;
    
    my $orig_new_socket = \&Slim::Networking::Async::HTTP::new_socket;
    
    no warnings 'redefine';
    *Slim::Networking::Async::HTTP::new_socket = sub {
        my $self = shift;
        my %args = @_;
        
        my $host = $self->request->uri->host;
        
        if ($host =~ /seva\.ru/i && $prefs->get('use_proxy')) {
            my $proxy_addr = $prefs->get('proxy_address');
            my $proxy_port = $prefs->get('proxy_port');
            my $proxy_user = $prefs->get('proxy_username');
            my $proxy_pass = $prefs->get('proxy_password');
            
            my $dest_host = $host;
            my $dest_port = $self->request->uri->port || 443;
            my $is_https = ($self->request->uri->scheme eq 'https');
            
            my $insecure = Slim::Utils::Prefs::preferences('server')->get('insecureHTTPS') || 0;
            my $timeout = $args{Timeout} || 10;
            
            $log->info("SimpleAsyncHTTP new_socket intercept: connecting to $dest_host:$dest_port via HTTP proxy $proxy_addr:$proxy_port");
            
            my $sock = connect_via_proxy(
                'http', $proxy_addr, $proxy_port, $proxy_user, $proxy_pass,
                $dest_host, $dest_port, $is_https, $timeout, $insecure
            );
            
            if ($sock) {
                my $target_class = $is_https 
                    ? 'Slim::Networking::Async::Socket::HTTPS' 
                    : 'Slim::Networking::Async::Socket::HTTP';
                bless $sock, $target_class;
                
                $sock->blocking(0);
                
                return $sock;
            } else {
                $log->error("SimpleAsyncHTTP intercept: proxy connection failed");
                return undef;
            }
        }
        
        return $orig_new_socket->($self, @_);
    };
}

1;
