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
use DateTime;
use Tie::IxHash;


has 'mech'     => (is => 'rw', isa => 'Str');
has 'base_url' => (is => 'rw', isa => 'Str');
has 'key'      => (is => 'rw', isa => 'Str');
has 'secret'   => (is => 'rw', isa => 'Str');

has 'accountInfo' => (is => 'rw', isa => 'Str');

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

# Get taker and maker fees
sub getFees {
    my $self   = shift;

#    my $account;
#    if ($self->{accountInfo}) {
#        $account = $self->{accountInfo};
#    } else {
#        $account = $self->_get('v3/account', 1);
#    }
#    my $fees = {
#        taker => $account->{takerCommission} / 10000,
#        maker => $account->{makerCommission} / 10000,
#    };
    
    my $fees = {
        taker => get_config_value('takerFee', $self->name),
        maker => get_config_value('makerFee', $self->name),
    };

    return $fees;
}


# Get precision of price and amount for market
sub getPrecision {
    my $self   = shift;
    my $market = shift;
    
    my $symbol = $market;
    $symbol =~ s/^(\w{3})_(\w+)$/$2$1/;

    my $exchange_info = $self->_get('v1/exchangeInfo');
    my $symbol_info = [ grep $_->{symbol} eq $symbol, @{ $exchange_info->{symbols} } ]->[0];

    my $price_filter = [ grep $_->{filterType} eq 'PRICE_FILTER', @{ $symbol_info->{filters} } ]->[0];
    my $lot_size = [ grep $_->{filterType} eq 'LOT_SIZE', @{ $symbol_info->{filters} } ]->[0];
    
    my $precisions = {price => index($price_filter->{minPrice}, 1) - 1, amount => index($lot_size->{minQty}, 1) - 1};

    return $precisions;
}

# Cancels an order
sub cancelOrder ($) {
    my $self     = shift;
    my $order_id = shift;
    my $market   = shift;
    
    my $symbol = $market;
    $symbol =~ s/^(\w{3})_(\w+)$/$2$1/;

    my $rs = $self->_delete('v3/order', 1, { symbol => $symbol, orderId => $order_id });
    $log->info(Dumper $rs) if $rs;

    return $rs;
}

# Places a buy/sell order in a given market.
sub createOrder ($$) {
    my $self   = shift;
    my $type   = shift;
    my $params = shift;

    my $symbol = $params->{market};
    $symbol =~ s/^(\w{3})_(\w+)$/$2$1/;

    my $rs = $self->_post('v3/order', 1,
        {
            symbol      => $symbol,
            side        => uc $type,
            type        => 'LIMIT',
            timeInForce => 'GTC',
            quantity    => $params->{amount},
            price       => $params->{price}
        }
    );
    $log->info(Dumper $rs) if $rs;

    return $rs;
}

# Returns your trade history
sub getTradeHistory ($) {
    my $self = shift;
    my $options = shift;

    my $open_orders = $self->_get('v3/openOrders', 1);
    my $markets = { map { $_->{symbol} => 1 } @$open_orders };
    
    my $trans;
    foreach my $market (keys %$markets) {
        my $rs = $self->_get('v3/allOrders', 1, {symbol => $market});
        my $filled_orders = { map {$_->{orderId} => $_} grep $_->{status} eq 'FILLED', @$rs };
        my $trades = $self->_get('v3/myTrades', 1, {symbol => $market});
        $market =~ s/^(\w+)(\w{3})$/$2_$1/;
        map {
            my $dt = DateTime->from_epoch(epoch => $_->{time} / 1000);
            my $type = $filled_orders->{ $_->{orderId} }->{side};
            my $fee = $type eq 'BUY' ? $_->{commission} / $_->{qty} : $_->{commission} / ($_->{price} * $_->{qty});
            push @{ $trans->{$market} },
              {
                orderNumber => $_->{orderId},
                market      => $market,
                type        => lc $type,
                price       => $_->{price},
                amount      => $_->{qty},
                fee         => sprintf("%.4f", $fee),
                fee_all     => sprintf("%.8f %s (%.2f)", $_->{commission}, $_->{commissionAsset}, $fee * 100),
                total       => sprintf("%.8f", $_->{price} * $_->{qty}),
                date        => $dt->ymd . ' ' . $dt->hms . '.' . sprintf("%03d", $dt->millisecond),
                tradeID     => $_->{id},
              }
        } sort {$a->{time} <=> $b->{time}} @$trades;
    }

    return $trans;
}

# Get all open orders
sub getOpenOrders () {
    my $self   = shift;
    my $market = shift;
    
    my $rs;
    if ($market) {
        my $symbol = $market;
        $symbol =~ s/^(\w{3})_(\w+)$/$2$1/;
        $rs = $self->_get('v3/openOrders', 1, { symbol => $symbol });
    } else {
        $rs = $self->_get('v3/openOrders', 1);
    }

    my $orders;
    map {
        my $market = $_->{symbol};
        $market =~ s/^(\w+)(\w{3})$/$2_$1/;
        my $dt = DateTime->from_epoch( epoch => $_->{time}/1000 );
        push @{ $orders->{$market} }, {
            order_id => $_->{orderId},
            type     => lc $_->{side},
            price    => $_->{price},
            amount   => $_->{origQty},
            filled   => sprintf("%.2f%%", $_->{executedQty} / $_->{origQty} * 100),
            total    => sprintf("%.8f", $_->{price} * $_->{origQty}),
            date     => $dt->ymd . ' ' .  $dt->hms . '.' . sprintf("%03d", $dt->millisecond),
        }
    } sort {$a->{symbol} cmp $b->{symbol} || $b->{price} <=> $a->{price}} @$rs;
#    $log->error(Dumper $orders);
#    exit;

    if ($market) {
        return $orders->{$market};
    } else {
        return $orders;
    }
}


# Returns all of your balances, including available, on orders, 
# and the estimated BTC value of your balance
sub getBalances () {
    my $self = shift;

    my $rs = $self->_get('v3/ticker/price');
    my $prices = {map {$_->{symbol} => $_->{price}} @$rs};

    $rs = $self->_get('v3/account', 1);
    my @balances = map {
        my $price = ($_->{asset} eq 'BTC') ? 1 : $prices->{"$_->{asset}BTC"};
        $price = ${ $self->_get('v3/ticker/price', 0, { symbol => "$_->{asset}BTC" }) }{price} unless ($price);
        {
            coin      => $_->{asset},
            locked    => $_->{locked},
            available => $_->{free},
            total     => sprintf("%.8f", $_->{free} + $_->{locked}),
            btc_value => sprintf("%.8f", $price * ($_->{free} + $_->{locked})),
        }
    } sort {$a->{asset} cmp $b->{asset}} grep $_->{free} > 0 || $_->{locked} > 0, @{ $rs->{balances} };

    return \@balances;
}

# Send GET request to Binance Public Rest API
sub _get ($;$$) {
    my $self   = shift;
    my $path   = shift;
    my $signed = @_ ? shift : 0;
    my $params = @_ ? shift : {};

    return $self->_send_request('GET', $path, $signed, $params);
}

# Send POST request to Binance Public Rest API
sub _post ($;$$) {
    my $self   = shift;
    my $path   = shift;
    my $signed = @_ ? shift : 0;
    my $params = @_ ? shift : {};

    return $self->_send_request('POST', $path, $signed, $params);
}

# Send DELETE request to Binance Public Rest API
sub _delete ($;$$) {
    my $self   = shift;
    my $path   = shift;
    my $signed = @_ ? shift : 1;
    my $params = @_ ? shift : {};

    return $self->_send_request('DELETE', $path, $signed, $params);
}

# Send PUT request to Binance Public Rest API
sub _put ($;$$) {
    my $self   = shift;
    my $path   = shift;
    my $signed = @_ ? shift : 0;
    my $params = @_ ? shift : {};

    return $self->_send_request('PUT', $path, $signed, $params);
}

# Send GET/POST/PUT/DELETE request to Binance Public Rest API
# For GET and DELETE endpoints, parameters will be sent as a query string
# For POST and PUT endpoints, the parameters will be sent in the request body 
# with content type application/x-www-form-urlencoded
sub _send_request ($$;$$) {
    my $self   = shift;
    my $type   = shift;     # request type: GET, POST, PUT, or DELETE
    my $path   = shift;
    my $signed = @_ ? shift : 1;
    my $params = @_ ? shift : {};

    return if (!$GO->{IN}->{run} and $type ne 'GET');
    
    my $url  = $self->{base_url};
    my $mech = $self->{mech};

    # ordered associative arrays for Perl
    # preserve the order in which the hash elements were added
    tie %$params, 'Tie::IxHash', %$params;

    $params->{timestamp} = int(time * 1000) if ($signed);
    my $query_string = join '&', map { "$_=$params->{$_}" } keys %$params;
    if ($signed) {
        my $signature = hmac_sha256_hex($query_string, $self->{secret});
        $query_string .= "&signature=$signature";
        $params->{signature} = $signature;
    }

    $url .= "/$path";
    $url .= "?$query_string" if (($type eq 'GET' || $type eq 'DELETE') && $query_string);
    $log->debug("$url?$query_string");
#    $log->debug(Dumper $params);

    my $response;
    if ($type eq 'GET') {
        $response = $mech->get($url);
    } elsif ($type eq 'POST') {
        $response = $mech->post($url, $params);
    } elsif ($type eq 'DELETE') {
        $response = $mech->delete($url);
    } elsif ($type eq 'PUT') {
        $response = $mech->put($url, $params);
    }

    return $self->_handle_response($response);
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

