#
#===============================================================================
#
#         FILE: API::Binance
#
#  DESCRIPTION: https://github.com/binance-exchange/binance-official-api-docs/blob/master/rest-api.md
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Charmarder
# ORGANIZATION: HeadStudio
#      VERSION: 1.0
#      CREATED: 1/29/2018 3:36:51 PM
#      CHANGED: $Date$
#   CHANGED BY: $Author$
#     REVISION: $Rev$
#===============================================================================
package API::Binance;

use strict;
use warnings;
use Moose;
use Data::Dumper;
use Util::Config;
use Util::Logger qw($log);

use Log::Log4perl::Level;
use WWW::Mechanize;
use Time::HiRes qw(time);
use Digest::SHA qw(hmac_sha256_hex);
use JSON;
use Date::Parse qw(str2time);


has 'mech'     => (is => 'rw', isa => 'Str');
has 'base_url' => (is => 'rw', isa => 'Str');
has 'key'      => (is => 'rw', isa => 'Str');
has 'secret'   => (is => 'rw', isa => 'Str');

sub BUILD { 
    my ($self, $args) = @_;  

    $log->level($DEBUG) if ($GO->{IN}->{debug});
    
    $self->{base_url} = 'https://api.binance.com/api';
    $self->{key} = get_config_value('key', 'Binance');
    $self->{secret} = get_config_value('secret', 'Binance');

    $ENV{PERL_LWP_SSL_VERIFY_HOSTNAME} = get_config_value('SSL_VERIFY_HOSTNAME', undef, 0); 

    $self->{mech} = WWW::Mechanize->new(autocheck => 0);
    my $proxy = get_config_value('proxy', undef, 0);
    $self->{mech}->proxy(['ftp', 'http', 'https'] => $proxy) if ($proxy);

    $self->{mech}->add_header(
        'Content-Type' => 'application/x-www-form-urlencoded',
        'X-MBX-APIKEY' => $self->{key},
    );
    
    return $self; 
}

# Return name of exchange
sub name {
    return 'Binance';
}

# Returns all of your balances, including available, on orders, 
# and the estimated BTC value of your balance

sub getBalances () {
    my $self = shift;

    my $rs = $self->_get_endpoint('v3/ticker/price');
    my $prices = {map {$_->{symbol} => $_->{price}} @$rs};

    $rs = $self->_get_endpoint('v3/account', 1);
    my @balances = map {
        my $price = ($_->{asset} eq 'BTC') ? 1 : $prices->{"$_->{asset}BTC"};
        {
            coin      => $_->{asset},
            locked    => $_->{locked},
            available => $_->{free},
            total     => sprintf("%.8f", $_->{free} + $_->{locked}),
            btc_value => sprintf("%.8f", $price * ($_->{free} + $_->{locked})),
        }
    } grep $_->{free} > 0 || $_->{locked} > 0, @{ $rs->{balances} };

    return \@balances;
}

# Send GET request to Binance Public Rest API
# For GET endpoints, parameters will be sent as a query string
sub _get_endpoint ($;$$) {
    my $self   = shift;
    my $path   = shift;
    my $signed = shift || 0;
    my $params = shift || {};

    my $url  = $self->{base_url};
    my $mech = $self->{mech};

    my $query_string = join '&', map { "$_=$params->{$_}" } keys %$params;
    if ($signed) {
        $query_string .= "&" if ($query_string);
        $query_string .= "timestamp=" . int(time * 1000);
        my $signature = hmac_sha256_hex($query_string, $self->{secret});
        $query_string .= "&signature=$signature";
    }

    $url .= "/$path";
    $url .= "?$query_string" if ($query_string);
    $log->debug($url);

    return $self->_handle_response($mech->get($url));
}

# Send POST request to Binance Public Rest API
# For POST, PUT, and DELETE endpoints, the parameters will be sent in the request body 
# with content type application/x-www-form-urlencoded
sub _post_endpoint ($;$) {
    my $self   = shift;
    my $path   = shift;
    my $signed = shift || 0;
    my $params = shift || {};

#    return if (!$GO->{IN}->{run});

    my $url  = $self->{base_url};
    my $mech = $self->{mech};

    my $query_string = join '&', map { "$_=$params->{$_}" } keys %$params;
    if ($signed) {
        $query_string .= "&" if ($query_string);
        $query_string .= "timestamp=" . int(time * 1000);
        my $signature = hmac_sha256_hex($query_string, $self->{secret});
        $query_string .= "&signature=$signature";
    }

    $url .= "/$path";
    $log->debug("$url?$query_string");

    return $self->_handle_response($mech->post($url, $params));
}

sub _handle_response {
    my $self     = shift; 
    my $response = shift;

    my $mech = $self->{mech};

    unless ($response->is_success) {
        $log->debug($mech->text());
        my $r = from_json($mech->text);
        $log->logdie('ERROR: HTTP Code: ' . $mech->status() . "; Binance Code: $r->{code}: $r->{msg}");
    } else {
        return from_json($mech->text());
    }
}


1;

