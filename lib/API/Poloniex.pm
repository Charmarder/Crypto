#
#===============================================================================
#
#         FILE: API::Poloniex
#
#  DESCRIPTION: https://poloniex.com/support/api/
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Charmarder
# ORGANIZATION: HeadStudio
#      VERSION: 1.0
#      CREATED: 1/11/2018 4:13:39 PM
#      CHANGED: $Date$
#   CHANGED BY: $Author$
#     REVISION: $Rev$
#===============================================================================
package API::Poloniex;

use strict;
use warnings;
use Moose;
use Data::Dumper;
use Util::Config;
use Util::Logger qw($log);

use Log::Log4perl::Level;
use WWW::Mechanize;
use Time::HiRes qw(time);
use Digest::SHA qw(hmac_sha512_hex);
use JSON;
use Date::Parse qw(str2time);


has 'mech'        => (is => 'rw', isa => 'Str');

has 'public_url'  => (is => 'rw', isa => 'Str');
has 'trading_url' => (is => 'rw', isa => 'Str');
has 'key'         => (is => 'rw', isa => 'Str');
has 'secret'      => (is => 'rw', isa => 'Str');

sub BUILD { 
    my ($self, $args) = @_;  

    $log->level($DEBUG) if ($GO->{IN}->{debug});
    
    $self->{public_url} = 'https://poloniex.com/public?command=';
    $self->{trading_url} = 'https://poloniex.com/tradingApi';
    $self->{key} = get_config_value('key', 'Poloniex');
    $self->{secret} = get_config_value('secret', 'Poloniex');

    $self->{mech} = WWW::Mechanize->new(autocheck => 0);
    my $proxy = get_config_value('proxy', undef, 0);
    $self->{mech}->proxy(['ftp', 'http', 'https'] => $proxy) if ($proxy);
 
    return $self; 
}

# Returns your trade history for a given market, specified by the "currencyPair" POST parameter.
# You may specify "all" as the currencyPair to receive your trade history for all markets. You may
# optionally specify a range via "start" and/or "end" POST parameters, given in UNIX timestamp
# format; if you do not specify a range, it will be limited to one day. You may optionally limit
# the number of entries returned using the "limit" parameter, up to a maximum of 10,000. If the 
# "limit" parameter is not specified, no more than 500 entries will be returned.
sub getTradeHistory ($) {
    my $self = shift;
    my $options = shift;

    my $params;
    if ($options->{market}) {
        $params->{start} = str2time(get_config_value($options->{market}, 'Poloniex'), 'GMT');
    } elsif ($options->{start}) {
        $params->{start} = str2time($options->{start}, 'GMT');
	}
    $params->{end} = str2time($options->{end}, 'GMT') if $options->{end};
    $params->{currencyPair} = $options->{market} ? $options->{market} : 'all';

    my $rs = $self->poloniex_trading_api('returnTradeHistory', $params);
    if ($options->{market}) {
    	return {$options->{market} => $rs};
    } else {
    	return $rs;
    }
}

# Returns your open orders for a given market, specified by the "currencyPair" POST parameter, e.g.
# "BTC_XCP". Set "currencyPair" to "all" to return open orders for all markets.
sub getOpenOrders () {
    my $self = shift;

    my $rs = $self->poloniex_trading_api('returnOpenOrders', {currencyPair => 'all'});

    return $rs;
}

# Returns all of your balances, including available balance, balance on orders, and the estimated 
# BTC value of your balance. By default, this call is limited to your exchange account; set the 
# "account" POST parameter to "all" to include your margin and lending accounts.
sub getBalances () {
    my $self = shift;

    my $rs = $self->poloniex_trading_api('returnCompleteBalances');

    my @balances = map {
        {
            coin      => $_,
            locked    => $rs->{$_}->{onOrders},
            available => $rs->{$_}->{available},
			total 	  => sprintf("%.8f", $rs->{$_}->{available} + $rs->{$_}->{onOrders}),
			btc_value => $rs->{$_}->{btcValue},
        }
    } grep $rs->{$_}->{btcValue} > 0, sort keys %$rs;

    $self->{mech}->get("https://min-api.cryptocompare.com/data/price?fsym=BTC&tsyms=USD");
    my $btcusd = from_json($self->{mech}->text())->{USD};
    
    return \@balances, $btcusd;
}


###############################################################################
# Public and Privat API functions
############################################################################### 

# returnTicker - Returns the ticker for all markets.
# return24Volume - Returns the 24-hour volume for all markets, plus totals for primary currencies.
# returnOrderBook&currencyPair=BTC_NXT&depth=10 - Returns the order book for a given market, 
#       as well as a sequence number for use with the Push API and an indicator specifying whether
#       the market is frozen. You may set currencyPair to "all" to get the order books of all markets.
# returnTradeHistory&currencyPair=BTC_NXT&start=1410158341&end=1410499372 - Returns the past 200
#       trades for a given market, or up to 50,000 trades between a range specified in UNIX timestamps
#       by the "start" and "end" GET parameters.
# returnChartData&currencyPair=BTC_XMR&start=1405699200&end=9999999999&period=14400 - Returns
#       candlestick chart data. Required GET parameters are "currencyPair", "period" (candlestick 
#       period in seconds; valid values are 300, 900, 1800, 7200, 14400, and 86400), "start", and
#       "end". "Start" and "end" are given in UNIX timestamp format and used to specify the date
#       range for the data returned.
# returnCurrencies - Returns information about currencies.
# returnLoanOrders&currency=BTC - Returns the list of loan offers and demands for a given currency,
#       specified by the "currency" GET parameter.
sub poloniex_public_api ($$;$) {
    my $self = shift; 
    my $method = shift;
    my $params = shift || {};
    
    my $url = $self->{public_url};
    my $mech = $self->{mech};

    $url .= $method;
    if (scalar keys %$params) {
        $url .= '&' . join '&', map {"$_=$params->{$_}"} keys %$params;
    }
    $log->debug($url);

    return $self->_handle_response($mech->get($url));
}

###############################################################################
# returnBalances
# returnCompleteBalances
# returnDepositAddresses
# generateNewAddress
# returnDepositsWithdrawals
# returnOpenOrders
# returnTradeHistory
# returnOrderTrades
# buy
# sell
# cancelOrder
# moveOrder
# withdraw
# returnFeeInfo
# returnAvailableAccountBalances
# returnTradableBalances
#
# transferBalance
#
# returnMarginAccountSummary
# marginBuy
# marginSell
# getMarginPosition
# closeMarginPosition
#
# createLoanOffer
# cancelLoanOffer
# returnOpenLoanOffers
# returnActiveLoans
# returnLendingHistory
# toggleAutoRenew
sub poloniex_trading_api ($$;$) {
    my $self = shift; 
    my $method = shift;
    my $params = shift || {};

    return if (!$GO->{IN}->{run} && $method !~ /^return/);

    my $url = $self->{trading_url};
    my $mech = $self->{mech};

    my $data = {
        command => $method,
        nonce   => time * 100000,
        %$params,
    };
    my $data_string = join '&', map {"$_=$data->{$_}"} keys %$data;
    $log->debug("$url?$data_string");

    my $signature = hmac_sha512_hex($data_string, $self->{secret});
    $mech->add_header(
#		'Content-Type' => 'application/x-www-form-urlencoded',
        'Key'          => $self->{key},
        'Sign'         => $signature,
    );
#    $log->debug($signature);

    my $response = $mech->post($url, $data);
    unless ($response->is_success) {
        $log->debug($mech->text());
        my $r = from_json($mech->text);
        $log->logdie('ERROR: HTTP Code: ' . $mech->status() . ": $r->{error}");
    } else {
        return from_json($mech->text());
    }

    return $self->_handle_response($mech->post($url, $data));
}


sub _handle_response {
    my $self     = shift; 
    my $response = shift;

    my $mech = $self->{mech};

    $log->debug($mech->text());
    $log->debug($response->is_success);
    unless ($response->is_success) {
        $log->debug($mech->text());
        my $r = from_json($mech->text);
        $log->logdie('ERROR: HTTP Code: ' . $mech->status() . ": $r->{error}");
    } else {
        return from_json($mech->text());
    }
}

1;

