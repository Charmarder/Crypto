#
#===============================================================================
#
#         FILE: BuyLowSellHigh.pm
#
#  DESCRIPTION: Buy Low Sell High strategy
#
#        FILES: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Charmarder
# ORGANIZATION: HeadStudio
#      VERSION: 1.0
#      CREATED: 1/16/2018 7:27:21 PM
#      CHANGED: $Date$
#   CHANGED BY: $Author$
#     REVISION: $Rev$
#===============================================================================
package Strategy::BuyLowSellHigh;

use strict;
use warnings;
use Moose;
use Data::Dumper;
use Util::Config;
use Util::Logger qw($log);

use Log::Log4perl::Level;

has 'price_step'  => (is => 'rw', isa => 'Str');
has 'amount_increase' => (is => 'rw', isa => 'Str');

sub BUILD { 
    my ($self, $args) = @_;  

    $log->level($DEBUG) if ($GO->{IN}->{debug});

    $self->{price_step}      = get_config_value('PriceStep');
    $self->{amount_increase} = get_config_value('AmountIncrease');
    
    return $self; 
}


# It will compose buy or sell order list 
sub calculateOrderList ($;$) {
    my $self = shift;
    my $start_price = shift;
    my $type = shift || 'buy';

    $log->debug($start_price);

    my $max_total_sum = 0.02;
#    my $sum = 
#    for my $i (15..0)

}


# Calculate Buy/Sell Average Price, Total Amount and Toral Sum, as well Amount Rest and Profit/Lost
sub getAnalysis {
    my $self         = shift;
    my $transactions = shift;

    my $analysis = {
        buy => {
            price  => 0,
            amount => 0,
            sum    => 0,
        },
        sell => {
            price        => 0,
            amount       => 0,
            sum          => 0,
            sum_with_fee => 0,
        },
        amount_rest => 0,
        profit_lost => 0,
        can_trade   => 0,
        new_sell    => {},
        new_buy     => {},
    };

    foreach (@$transactions) {
        if ($_->{type} eq 'buy') {
            $analysis->{buy}->{amount} += $_->{amount} * (1 - $_->{fee});
            $analysis->{buy}->{sum} += $_->{amount} * $_->{rate};
        } elsif ($_->{type} eq 'sell') {
            $analysis->{sell}->{amount} += $_->{amount};
            $analysis->{sell}->{sum} += $_->{amount} * $_->{rate} * (1 - $_->{fee});
            $analysis->{sell}->{sum_with_fee} += $_->{amount} * $_->{rate};
        }
    }

    if ($analysis->{buy}->{sum}) {
        $analysis->{buy}->{price} = $analysis->{buy}->{sum} / $analysis->{buy}->{amount};
    }
    if ($analysis->{sell}->{sum}) {
        $analysis->{sell}->{price} = $analysis->{sell}->{sum} / $analysis->{sell}->{amount};
    }
    $analysis->{amount_rest} = $analysis->{buy}->{amount} - $analysis->{sell}->{amount};
    $analysis->{profit_lost} = $analysis->{sell}->{sum} - $analysis->{buy}->{sum};

    return $analysis;
}

# Return parameters for new sell order
sub calculateSell {
    my $self      = shift;
    my $market    = shift;
    my $buy_price = shift;
    my $buy_sum   = shift;
    my $sell_sum  = shift;

    my $new_sell;

    my $take_profit = get_config_value('TakeProfit', $market);
    my $ROI = get_config_value('ROI');

    $new_sell->{price} = $buy_price * (1 + $take_profit);
    $new_sell->{sum} = ($buy_sum * (1 + $ROI) - $sell_sum)  / 0.9985;
    $new_sell->{amount} = $new_sell->{sum} / $new_sell->{price};
    $new_sell->{take_profit} = $take_profit;
    $new_sell->{ROI} = $ROI;

    return $new_sell;
}

# Return parameters for new sell order
sub calculateBuy {
    my $self          = shift;
    my $market        = shift;
    my $trans         = shift;
    my $market_orders = shift;
    my $analysis      = shift;

    my $new_buy;

    # find stat price and start amount
    my $first_order = [sort {$a->{date} cmp $b->{date}} @$trans]->[0];
    my $last_order  = [sort {$b->{date} cmp $a->{date}} @$trans]->[0];
    $log->error(Dumper $first_order);
    $log->error(Dumper $last_order);

    return $new_buy;
}

# Analysis and trade
sub trade ($;$) {
    my $self     = shift;
    my $exchange = shift;
    my $options  = shift;

    my $transactions = $exchange->getTradeHistory($options);
    my $orders       = $exchange->getOpenOrders();

    my @markets;
    if ($options->{market}) {
        @markets = $options->{market};
    } else {
        @markets = grep scalar @{ $orders->{$_} }, sort keys %$orders;
    }

    foreach my $market (@markets) {
        print '-' x length($market) . "\n$market\n" . '-' x length($market) . "\n";

        my $start_date = get_config_value($market, 'Poloniex');
        my @trans = grep $_->{date} ge $start_date, map { $_->{market} = $market; $_  } @{ $transactions->{$market} };

        my $analysis = $self->getAnalysis(\@trans);

        my $new_sell;
        if ($analysis->{profit_lost} < 0) {
            # Get parameters for new sell order (Price, Amount and Sum)
            $new_sell = $self->calculateSell($market, 
                $analysis->{buy}->{price}, $analysis->{buy}->{sum}, $analysis->{sell}->{sum});

            # Step 1: Cancel old sell order if exist and create new one if not exist
            my $market_orders = $orders->{$market};
            my $new_sell_amount = sprintf("%.8f", $new_sell->{amount});
            if (! grep $_->{type} eq 'sell' && $_->{amount} == $new_sell_amount, @$market_orders) {
                # Be sure that there is no more then one sell order
                my @sell_orders = grep $_->{type} eq 'sell', @$market_orders;
                if (@sell_orders > 1) {
                    $log->warn('Cannot do anythig, there are more then one sell orders.');
                } else {
                    if (@sell_orders) {
                        # Cancel old sell order
                        my $o = $sell_orders[0];
                        $log->info("Cancel old Sell order $o->{orderNumber}");
                        my $rs = $exchange->poloniex_trading_api('cancelOrder', { orderNumber => $o->{orderNumber} });
                        $log->info(Dumper $rs) if $rs;
                    }

                    # Place new sell order
                    my $new_sell_order_params = {
                        currencyPair => $market,
                        rate         => sprintf("%.8f", $new_sell->{price} ),
                        amount       => $new_sell_amount,
                        postOnly     => 1,
                    };
                    $log->info("Create new Sell order: " . Dumper $new_sell_order_params);
                    my $rs = $exchange->poloniex_trading_api('sell', $new_sell_order_params);
                    $log->info(Dumper $rs) if $rs;
                }
            } else {
                $log->debug("Nothing to do, sell order with amount $new_sell_amount already exist.");
            }

            # Get parameters for new sell order (Price, Amount and Sum)
#            my $new_buy = $self->calculateBuy($market, \@trans, $market_orders, $analysis);

            # Step 2: Create new buy orders if not exist yet


        } else {
            # Cances all orders
            foreach my $o (@{ $orders->{$market} }) {
                $log->info("Cancel order $o->{orderNumber}");
                my $rs = $exchange->poloniex_trading_api('cancelOrder', { orderNumber => $o->{orderNumber} });
                $log->info(Dumper $rs) if $rs;
            }
        }


        if ($analysis->{buy}->{sum}) {
            printf("Total Buy (Price Amount Sum):\t%.8f\t%.8f\t%.8f\n", 
                $analysis->{buy}->{price}, $analysis->{buy}->{amount}, $analysis->{buy}->{sum});
        }
        if ($analysis->{sell}->{sum}) {
            printf("Total Sell (Price Amount Sum):\t%.8f\t%.8f\t%.8f\n",
                $analysis->{sell}->{price}, $analysis->{sell}->{amount}, $analysis->{sell}->{sum_with_fee});
        }
        
        my $msg = ($analysis->{profit_lost} > 0) ? 'You have earned' : 'Amount Rest';
        printf("$msg:\t%.8f\tProfit/Lost:\t%.8f\n\n", $analysis->{amount_rest}, $analysis->{profit_lost});

        if ($analysis->{profit_lost} < 0) {
            printf("Recomended Sell +" . $new_sell->{take_profit} * 100 . '%% ROI ' . $new_sell->{ROI} * 100 . '%%' .
                " (Price Amount Sum):\t%.8f\t%.8f\t%.8f\n",
                $new_sell->{price}, $new_sell->{amount}, $new_sell->{sum});
            printf("Amount will be earned:\t%.8f\n\n", $analysis->{amount_rest} - $new_sell->{amount});
        }

        # Get open orders for market and print
        my $orders = $exchange->poloniex_trading_api( 'returnOpenOrders', { currencyPair => $market } );
        my $header = ['OrderNumber', 'Type', 'Price', 'Amount', 'StartingAmount', 'Total', 'Date'];
        my $data;
        foreach ( sort {$b->{rate} <=> $a->{rate}} @$orders ) {
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

        # Print history for market
        $header = 
          ['OrderNumber', 'Market', 'Type', 'Price', 'Amount', 'Fee', 'Total', 'Date', 'TradeID', 'GlobalTradeID'];
        $data = [];
        foreach (sort {$a->{date} cmp $b->{date}} @trans) {
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
}

# Get trade history
sub getTradeHistory ($;$) {
    my $self     = shift;
    my $exchange = shift;
    my $options  = shift;

    my $transactions = $exchange->getTradeHistory($options);

    my @trans;
    foreach my $market (keys %$transactions) {
        push @trans, map { $_->{market} = $market; $_  } @{ $transactions->{$market} };
    }

    my $header = 
      ['OrderNumber', 'Market', 'Type', 'Price', 'Amount', 'Fee', 'Total', 'Date', 'TradeID', 'GlobalTradeID'];
    my $data;
    foreach (sort {$a->{date} cmp $b->{date}} @trans) {
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

# Get all open orders
sub getOpenOrders ($) {
    my $self = shift;
    my $exchange = shift;

    my $rs = $exchange->getOpenOrders();
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

# Get all information about balances
sub getBalances ($) {
    my $self = shift;
    my $exchange = shift;

    my ($header, $data, $total) = $exchange->getBalances();
    
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

1;

