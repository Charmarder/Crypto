#
#===============================================================================
#
#         FILE: API::CryptoCompare
#
#  DESCRIPTION: https://www.cryptocompare.com/api/
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Charmarder
# ORGANIZATION: HeadStudio
#      VERSION: 1.0
#      CREATED: 1/31/2018 3:28:37 AM
#      CHANGED: $Date$
#   CHANGED BY: $Author$
#     REVISION: $Rev$
#===============================================================================
package API::CryptoCompare;

use strict;
use warnings;
use Moose;
use Data::Dumper;
use Util::Config;
use Util::Logger qw($log);

use Log::Log4perl::Level;
use WWW::Mechanize;
use JSON;

has 'mech'     => (is => 'rw', isa => 'Str');
has 'base_url' => (is => 'rw', isa => 'Str');

sub BUILD { 
    my ($self, $args) = @_;  

    $log->level($DEBUG) if ($GO->{IN}->{debug});
    
    $self->{base_url} = 'https://min-api.cryptocompare.com';

    $self->{mech} = WWW::Mechanize->new(autocheck => 0);
    my $proxy = get_config_value('proxy', undef, 0);
    $self->{mech}->proxy(['ftp', 'http', 'https'] => $proxy) if ($proxy);

    return $self; 
}

sub get ($;$) {
    my $self  = shift;
    my $path  = shift;
    my $params = shift;

    my $url = "$self->{base_url}/data";
    my $query_string = join '&', map { "$_=$params->{$_}" } keys %$params;

    $url .= "/$path";
    $url .= "?$query_string" if ($query_string);
    $log->debug($url);

    return $self->_handle_response($self->{mech}->get($url));
}

sub _handle_response {
    my $self     = shift; 
    my $response = shift;

    my $mech = $self->{mech};

    unless ($response->is_success) {
        $log->logdie('ERROR: HTTP Code: ' . $mech->status() . "; $mech->text()");
    } else {
        my $r = from_json($mech->text);
        if (defined $r->{Response} && $r->{Response} eq 'Error' and $r->{Type} < 100) {
            $log->logdie('ERROR: HTTP Code: ' . $mech->status() . "; " . Dumper $r);
        } else {
            return $r;
        }
    }
}

1;

