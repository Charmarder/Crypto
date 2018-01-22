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

    $self->{mech} = WWW::Mechanize->new();
    my $proxy = get_config_value('proxy', undef, {}, 1);
    $self->{mech}->proxy(['ftp', 'http', 'https'] => $proxy) if ($proxy);
 
    return $self; 
}

# Returns your trade history for a given market, specified by the "currencyPair" POST parameter.
# You may specify "all" as the currencyPair to receive your trade history for all markets. You may
# optionally specify a range via "start" and/or "end" POST parameters, given in UNIX timestamp
# format; if you do not specify a range, it will be limited to one day. You may optionally limit
# the number of entries returned using the "limit" parameter, up to a maximum of 10,000. If the 
# "limit" parameter is not specified, no more than 500 entries will be returned.
sub returnTradeHistory () {
    my $self = shift;
    my $options = shift;

    my $params;
    if ($options->{start}) {
        $params->{start} = str2time($options->{start}, 'GMT');
    } elsif ($options->{currencyPair}) {
        $params->{start} = str2time(get_config_value($options->{currencyPair}, 'Poloniex'), 'GMT');
    }
    $params->{end} = str2time($options->{end}, 'GMT') if $options->{end};
    $params->{currencyPair} = $options->{currencyPair} ? $options->{currencyPair} : 'all';
    my $rs = $self->poloniex_trading_api('returnTradeHistory', $params);

    my @transactions; 
    if ($params->{currencyPair} eq 'all') {
        foreach my $market (keys %$rs) {
            push @transactions, map { $_->{market} = $market; $_  } @{ $rs->{$market} };
        }
    } else {
        push @transactions, map { $_->{market} = $params->{currencyPair}; $_  } @$rs;

        # Calculate Average Buy Price, Total Amount and Toral Sum
        my $total;
        map {
            $total->{buy_amount} += $_->{amount} * (1 - $_->{fee});
            $total->{buy_sum} += $_->{amount} * $_->{rate};
        } grep $_->{type} eq 'buy', @transactions;
        if ($total->{buy_sum}) {
            $total->{buy_average} = $total->{buy_sum} / $total->{buy_amount};
            printf("Total Buy (Price Amount Sum):\t%.8f\t%.8f\t%.8f\n", 
                $total->{buy_average}, $total->{buy_amount}, $total->{buy_sum});
            # Amount rest, Profit/Lost
            $total->{amount_rest} = $total->{buy_amount};
            $total->{profit_lost} = -$total->{buy_sum};
        }

        # Calculate Average Sell Price, Total Amount and Toral Sum
        map {
            $total->{sell_amount} += $_->{amount};
            $total->{sell_sum} += $_->{amount} * $_->{rate} * (1 - $_->{fee});
            $total->{sell_sum_with_fee} += $_->{amount} * $_->{rate};
        } grep $_->{type} eq 'sell', @transactions;
        if ($total->{sell_sum}) {
            $total->{sell_average} = $total->{sell_sum} / $total->{sell_amount};
            printf("Total Sell (Price Amount Sum):\t%.8f\t%.8f\t%.8f\n",
                $total->{sell_average}, $total->{sell_amount}, $total->{sell_sum_with_fee});
            # Amount rest, Profit/Lost
            $total->{amount_rest} = $total->{buy_amount} - $total->{sell_amount};
            $total->{profit_lost} = $total->{sell_sum} - $total->{buy_sum};
        } else {
            $total->{sell_sum} = 0;
            $total->{sell_sum_with_fee} = 0;
        }
        
        my $msg = ($total->{profit_lost} > 0) ? 'You have earned' : 'Amount Rest';
        printf("$msg:\t%.8f\tProfit/Lost:\t%.8f\n\n", $total->{amount_rest}, $total->{profit_lost});

        # Recomended Sell Price, Amount and Sum
        if ($total->{profit_lost} < 0) {
            my $take_profit = get_config_value('TakeProfit', $params->{currencyPair});
            my $ROI = get_config_value('ROI');
            $total->{recomended_price} = $total->{buy_average} * (1 + $take_profit);
            $total->{recomended_sum} = ($total->{buy_sum} - $total->{sell_sum_with_fee}) * (1 + $ROI) / 0.9985;
            $total->{recomended_amount} = $total->{recomended_sum} / $total->{recomended_price};
            printf("Recomended Sell +" . $take_profit * 100 . '%% ROI ' . $ROI * 100 . '%%' .
                " (Price Amount Sum):\t%.8f\t%.8f\t%.8f\n",
                $total->{recomended_price}, $total->{recomended_amount}, $total->{recomended_sum});
            printf("Amount will be earned:\t%.8f\n\n", $total->{amount_rest} - $total->{recomended_amount});

            # Get open order for currentPair
            my $orders = $self->poloniex_trading_api( 'returnOpenOrders', { currencyPair => $params->{currencyPair} } );
            my $header = ['OrderNumber', 'Type', 'Price', 'Amount', 'StartingAmount', 'Total', 'Date'];
            my $data;
            foreach ( @$orders ) {
                push @$data, [
                    $_->{orderNumber},
                    $_->{type},
                    $_->{rate},
                    $_->{amount},
                    $_->{startingAmount},
                    $_->{total},
                    $_->{date},
                ];
            }
            $self->print_table($header, $data);
           
            $total->{recomended_amount} = sprintf("%.8f", $total->{recomended_amount});
            if (! grep $_->{type} eq 'sell' && $_->{amount} == $total->{recomended_amount}, @$orders) {
                # Cancel old sell orders
                for my $o (grep $_->{type} eq 'sell', @$orders) {
                    $rs = $self->poloniex_trading_api('cancelOrder', { orderNumber => $o->{orderNumber} });
                    $log->info(Dumper $rs) if $rs;
                }

                # Place new sell order
                my $new_sell_order_params = {
                    currencyPair => $params->{currencyPair},
                    rate         => sprintf("%.8f", $total->{recomended_price} ),
                    amount       => $total->{recomended_amount},
                    postOnly     => 1,
                };
                $log->info("New Sell order parameters: " . Dumper $new_sell_order_params);
                $rs = $self->poloniex_trading_api('sell', $new_sell_order_params);
                $log->info(Dumper $rs) if $rs;
            } else {
                $log->debug('Nothing to do, sell order already exist.');
            }
        }
    }
    @transactions = sort {$a->{date} cmp $b->{date}} @transactions;

    my $header = 
      ['OrderNumber', 'Market', 'Type', 'Price', 'Amount', 'Fee', 'Total', 'Date', 'TradeID', 'GlobalTradeID'];
    my $data;
    foreach (@transactions) {
            push @$data, [
                $_->{orderNumber},
                $_->{market},
                $_->{type},
                $_->{rate},
                $_->{amount},
                $_->{fee},
                $_->{total},
                $_->{date},
                $_->{tradeID},
                $_->{globalTradeID},
            ];
    }
    $self->print_table($header, $data);
}

# Returns your open orders for a given market, specified by the "currencyPair" POST parameter, e.g.
# "BTC_XCP". Set "currencyPair" to "all" to return open orders for all markets.
sub returnOpenOrders () {
    my $self = shift;

    my $rs = $self->poloniex_trading_api('returnOpenOrders', {currencyPair => 'all'});
    my @markets = grep scalar @{ $rs->{$_} }, sort keys %$rs;
    
    my $header = ['OrderNumber', 'Type', 'Price', 'Amount', 'StartingAmount', 'Total', 'Date'];
    my $data;
    foreach my $market (@markets) {
        my $group = {name => $market};  #TODO add current price
        foreach ( @{ $rs->{$market} } ) {
            push @{ $group->{data} }, [
                $_->{orderNumber},
                $_->{type},
                $_->{rate},
                $_->{amount},
                $_->{startingAmount},
                $_->{total},
                $_->{date},
            ];
        }
        push @$data, $group;
    }
    $self->print_table($header, $data);
}

# Returns all of your balances, including available balance, balance on orders, and the estimated 
# BTC value of your balance. By default, this call is limited to your exchange account; set the 
# "account" POST parameter to "all" to include your margin and lending accounts.
sub returnCompleteBalances () {
    my $self = shift;

    my $rs = $self->poloniex_trading_api('returnCompleteBalances');
    my @coins = grep $rs->{$_}->{btcValue} > 0, sort keys %$rs;

    my $header = ['Coin', 'Total', 'On Orders', 'Available', 'BTC Value'];
    my $data;
    my $total_btc;
    foreach (@coins) {
        $total_btc += $rs->{$_}->{btcValue};
        push @$data, [
            $_,
            sprintf("%.8f", $rs->{$_}->{available} + $rs->{$_}->{onOrders}),
            $rs->{$_}->{onOrders},
            $rs->{$_}->{available},
            $rs->{$_}->{btcValue},
        ];
    }

    $rs = $self->{mech}->get("https://min-api.cryptocompare.com/data/price?fsym=BTC&tsyms=USD");
    my $btcusd = from_json($self->{mech}->text())->{USD};
    my $total = sprintf("Total Balance: %.2f USD / %.8f BTC\n", $btcusd * $total_btc, $total_btc);

    $self->print_table($header, $data, $total);
}


###############################################################################
# Helper functions
###############################################################################

# Print data to console as table
sub print_table ($$;$) {
    my $self   = shift;
    my $header = shift;
    my $data   = shift;
    my $total  = shift;

    # calculate lengths of columns
    my $lengths = [ map { length $_ } @$header ];

    my $rows = (ref $data->[0] eq 'HASH') ? [ map { @{ $_->{data} } } @$data ] : $data;
    foreach my $row (@$rows) {
        for (my $i = 0; $i < @$row; $i++) {
            my $l = length $row->[$i];
            $lengths->[$i] = $l if ($lengths->[$i] < $l);
        }
    }
    $log->debug(Dumper $lengths);

    # calculate table width (2 spaces bitween columns)
    my $width += 2 * (@$lengths - 1);
    $width += $_ for @$lengths;
    $log->debug(Dumper $width);

    # compose format strings for sprintf()
    my $format = {
        header => join( '  ', map { '%-' . $_ . 's' } @$lengths ),
        body   => join( '  ', map { '%' . $_ . 's' } @$lengths ),
    };
    $format->{body} =~ s/^(\%)/$1-/;
    $log->debug(Dumper $format);

    # print table(s) content
    my $groups = (ref $data->[0] eq 'HASH') ? $data : [ {name => '...', data => $data} ];
    for my $group (@$groups) {
        print "$group->{name}\n" if ($group->{name} ne '...');
        printf('-' x $width . "\n" . "$format->{header}\n" . '-' x $width . "\n", @$header);
        printf("$format->{body}\n", @$_) for (@{ $group->{data} });
        print '-' x $width . "\n\n";
    }

    print "$total\n" if ($total);
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

    my $res = $mech->get($url);
    unless ($res->is_success) {
        die Dumper($mech->status());
    } else {
        return from_json($mech->text());
    }
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
        nonce   => time =~ s/\.//r,
        %$params,
    };
    my $data_string = join '&', map {"$_=$data->{$_}"} keys %$data;
    $log->debug("$url?$data_string");

    my $signature = hmac_sha512_hex($data_string, $self->{secret});
    $mech->add_header(
		'Content-Type' => 'application/x-www-form-urlencoded',
        'Key'          => $self->{key},
        'Sign'         => $signature,
    );
#    $log->debug($signature);

    my $res = $mech->post($url, $data);
    unless ($res->is_success) {
        die Dumper($mech->status());
    } else {
        return from_json($mech->text());
    }
}

1;

