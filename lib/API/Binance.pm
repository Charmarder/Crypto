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

    $self->{mech} = WWW::Mechanize->new(autocheck => 0);
    my $proxy = get_config_value('proxy', undef, 0);
    $self->{mech}->proxy(['ftp', 'http', 'https'] => $proxy) if ($proxy);

    $self->{mech}->add_header(
		'Content-Type' => 'application/x-www-form-urlencoded',
        'X-MBX-APIKEY' => $self->{key},
    );
    
    return $self; 
}

sub getBalances () {
    my $self = shift;

#    my $rs = $self->_get_endpoint('time');
#    $log->debug(Dumper $rs);
#    my $rs = $self->_get_endpoint('depth', {symbol => 'ETHBTC', limit => 5});
#    my $rs = $self->_get_endpoint('trades', {symbol => 'ETHBTC'});
#    my $rs = $self->_get_endpoint('historicalTrades', {symbol => 'ETHBTC'});
    my $rs = $self->_get_endpoint('account', 1);
    $log->debug(Dumper $rs);

#    my @a = grep $_->{quoteAsset} eq 'BTC' && $_->{filters}->[2]->{minNotional} < 0.002, @{ $rs->{symbols} };
##    $log->debug(Dumper @a);
#    @a = map {"$_->{symbol} $_->{filters}->[2]->{minNotional}"} @a;
#    $log->debug(Dumper \@a);
#
#    my @b = grep $_->{quoteAsset} eq 'ETH' && $_->{filters}->[2]->{minNotional} < 0.02, @{ $rs->{symbols} };
#    @b = map {$_->{symbol}} @b;
#    $log->debug(Dumper \@b);
#
#    my @c = grep $_->{quoteAsset} eq 'BNB' && $_->{filters}->[2]->{minNotional} < 1, @{ $rs->{symbols} };
#    @c = map {$_->{symbol}} @c;
#    $log->debug(Dumper \@c);
#
#    my @d = grep $_->{quoteAsset} eq 'USDT' && $_->{filters}->[2]->{minNotional} < 20, @{ $rs->{symbols} };
#    @d = map {"$_->{symbol} $_->{filters}->[2]->{minNotional}"} @d;
#    $log->debug(Dumper \@d);

    exit;
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

    my $v = ($signed) ? 'v3' : 'v1';
    $url .= "/$v/$path";
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

    my $v = ($signed) ? 'v3' : 'v1';
    $url .= "/$v/$path";
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

