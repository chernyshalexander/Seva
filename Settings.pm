package Plugins::Seva::Settings;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Strings qw(string);
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.seva');

sub name {
    return 'PLUGIN_SEVA';
}

sub page {
    return 'plugins/Seva/settings/basic.html';
}

sub prefs {
    return ($prefs, qw(demostrate_photos photo_interval use_proxy proxy_address proxy_port proxy_username proxy_password));
}

1;
