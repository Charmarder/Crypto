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
has 'amount_step' => (is => 'rw', isa => 'Str');

sub BUILD { 
    my ($self, $args) = @_;  

    $log->level($DEBUG) if ($GO->{IN}->{debug});

    $self->{price_step}  = get_config_value('PriceStep');
    $self->{amount_step} = get_config_value('AmountStep');
    
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


# It analyses market trades and 
# calculate Buy/Sell Average Price, Total Amount and Toral Sum, 
# as well Amount Rest, Profit/Lost, Break-Ever Price and other
sub getAnalysis ($$$$) {
    my $self     = shift;
    my $market   = shift;
    my $exchange = shift;
    my $trades   = shift;
    my $orders   = shift;

    my $analysis = {
        market    => $market,
        side      => (@$trades) ? $trades->[0]->{type} : $orders->[0]->{type},    # buy|sell
        status    => '',  # new|trading|completed
        buy       => {
            price  => 0,
            amount => 0,
            sum    => 0,
        },
        sell => {
            price  => 0,
            amount => 0,
            sum    => 0,
        },
        amount_rest      => 0,
        break_even_price => 0,
        profit_lost      => 0,
        take_profit      => get_config_value('TakeProfit', $market),
        ROI              => get_config_value('ROI', $market),
        price_step       => get_config_value('PriceStep', $market),
        amount_step      => get_config_value('AmountStep', $market),
        fees             => $exchange->getFees(),
        precisions       => $exchange->getPrecision($market),
    };

#    $log->info(Dumper $trades);

    foreach (@$trades) {
        if ($_->{type} eq 'buy') {
            $analysis->{buy}->{amount} += $_->{amount} * (1 - $_->{fee});
            $analysis->{buy}->{sum} += $_->{amount} * $_->{price};
        } elsif ($_->{type} eq 'sell') {
            $analysis->{sell}->{amount} += $_->{amount};
            $analysis->{sell}->{sum} += $_->{amount} * $_->{price} * (1 - $_->{fee});
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

    # Set status of trading to 'new' (not started), 'trading' (in process of trade) or 'competed' (got profit)
    $analysis->{status} = (@$trades) ? 
        ($analysis->{profit_lost} < 0 || $analysis->{amount_rest} < 0 ? 'trading' : 'completed') : 'new';

    # Set 'side' depending values
    if ($analysis->{side} eq 'buy') {
        if ($analysis->{profit_lost} < 0) {
            $analysis->{break_even_price} = $analysis->{profit_lost} * -1
                / (1 - $analysis->{fees}->{maker}) / $analysis->{amount_rest};
        }
    } else {
        if ($analysis->{amount_rest} < 0) {
            $analysis->{break_even_price} = $analysis->{profit_lost}
                / ($analysis->{amount_rest} * -1 / (1 - $analysis->{fees}->{maker}));
        }
    }

    return $analysis;
}

# Return parameters for new Take Profit (sell/buy) order
sub getTakeProfit {
    my $self      = shift;
    my $analysis  = shift;

    my $buy_price   = $analysis->{buy}->{price};
    my $buy_sum     = $analysis->{buy}->{sum};
    my $sell_sum    = $analysis->{sell}->{sum};
    my $take_profit = $analysis->{take_profit};
    my $ROI         = $analysis->{ROI};

    my $precision_price  = $analysis->{precisions}->{price};
    my $precision_amount = $analysis->{precisions}->{amount};

    my $new_order;

    $new_order->{price} = $analysis->{break_even_price} * (1 + $take_profit);
    $new_order->{sum} = ($buy_sum - $sell_sum) * (1 + $ROI)  / (1 - $analysis->{fees}->{maker});
    $new_order->{amount} = sprintf("%.${precision_amount}f", $new_order->{sum} / $new_order->{price});
    $new_order->{price} = sprintf("%.${precision_price}f", $new_order->{price});
    $new_order->{type} = $analysis->{side} eq 'buy' ? 'sell' : 'buy';

    return $new_order;
}

# Return array of parameters for new Step (sell/buy) orders
sub getStepOrders ($$$) {
    my $self     = shift;
    my $analysis = shift;
    my $trades   = shift;
    my $orders   = shift;

    my $market     = $analysis->{market};
    my $side       = $analysis->{side};

    my $max_orders = get_config_value('MaxStepOrders', $market);
    my $step_orders = [ grep $_->{type} eq $side, @$orders ];

    return [] if (@$step_orders >= $max_orders);

    # Find Start Price and Start Amount
    my ($start_price, $start_amount);
    if (@$trades) {
        foreach (sort {$a->{date} cmp $b->{date}} grep $_->{type} eq $side, @$trades) {
            if (! defined $start_price) {
                $start_price = $_->{price};
                $start_amount = $_->{amount};
            } elsif ($start_price == $_->{price}) {
                $start_amount += $_->{amount};
            } else {
                last;
            }
        }
    } else {
        my $o = [sort {$a->{date} cmp $b->{date}} grep $_->{type} eq $side, @$orders]->[0];
        $start_price = $o->{price};
        $start_amount = $o->{amount};
    }
    $log->debug("Start Price and Amount: $start_price, $start_amount");

    # Сalculate array of Step orders
    my @steps;
    my $price_step = $analysis->{price_step};
    my $amount_step = $analysis->{amount_step};
    my $max_steps = int(50 / ($price_step * 100));
    my $precision_price  = $analysis->{precisions}->{price};
    my $precision_amount = $analysis->{precisions}->{amount};
    for (my $i = 0; $i < $max_steps; $i++) {
        my $price = $start_price * (1 -  $price_step * $i * ($side eq 'buy' ? 1 : -1));
        my $amount = $start_amount * (1 + $amount_step) ** $i;
        push @steps, {
            market => $market,
            price  => sprintf("%.${precision_price}f", $price),
            amount => sprintf("%.${precision_amount}f", $amount),
        };
    }

    # Find last Step order from orders or trades
    my $last_order;
    if (@$step_orders) {
        if ($side eq 'buy') {
            $last_order = [sort {$a->{price} cmp $b->{price}} @$step_orders]->[0];
        } else {
            $last_order = [sort {$b->{price} cmp $a->{price}} @$step_orders]->[0];
        }
    } else {
        if ($side eq 'buy') {
            $last_order  = [sort {$a->{price} cmp $b->{price}} grep $_->{type} eq $side, @$trades]->[0];
        } else {
            $last_order  = [sort {$b->{price} cmp $a->{price}} grep $_->{type} eq $side, @$trades]->[0];
        }
    }
    $log->debug(Dumper $last_order);

    # Grep not created Step orders
    my $not_created;
    if ($side eq 'buy') {
        $not_created = [grep $_->{price} < $last_order->{price}, @steps];
    } else {
        $not_created = [grep $_->{price} > $last_order->{price}, @steps];
    }
#    $log->info(Dumper $not_created);

    # Return not more then MaxStepOrders
    my $num = ($max_orders - @$step_orders > @$not_created ? @$not_created : $max_orders - @$step_orders) - 1;
    return [ (@$not_created)[ 0 .. $num ] ];
}

# Main function for automation trading
sub trade ($;$) {
    my $self     = shift;
    my $exchange = shift;
    my $options  = shift;

    $options->{start} = get_config_value('StartTradeDate', $exchange->name);

    my $trades = $exchange->getTradeHistory($options);
    my $orders = $exchange->getOpenOrders();

    my @markets;
    if ($options->{market}) {
        @markets = $options->{market};
    } else {
        @markets = grep scalar @{ $orders->{$_} }, sort keys %$orders;
    }
    $log->debug(Dumper \@markets);

    foreach my $market (@markets) {
        my $start_date = get_config_value($market, $exchange->name);
        my @trades = grep $_->{date} ge $start_date, map { $_->{market} = $market; $_  } @{ $trades->{$market} };

#        next unless scalar @trades;

        my $market_orders = $orders->{$market};

        my $analysis = $self->getAnalysis($market, $exchange, \@trades, $market_orders);
        $log->debug(Dumper $analysis);

        # Print market header
        my $h = sprintf("%s %d%% / %d%% (%s)",
            $market, $analysis->{price_step} * 100, $analysis->{amount_step} * 100, $analysis->{side});
        print '-' x length($h) . "\n$h\n" .  '-' x length($h) . "\n";

        my $new_take_profit;
        if ($analysis->{status} eq 'trading') {
            # Get parameters (Price, Amount and Sum) for new Take Profit order
            $new_take_profit = $self->getTakeProfit($analysis);
            $log->debug("New Take Profit order: " . Dumper $new_take_profit);

            # Cancel old Take Profit order if exist and create new one if not exist
            my $pt_type = $new_take_profit->{type};
            my @take_profit_orders = grep $_->{type} eq $pt_type, @$market_orders;
            if (@take_profit_orders > 1) {
                # Be sure that there is no more then one Take Profit order
                $log->warn("Cannot do anythig, there are more then one Take Profit ($pt_type) orders.");
            } elsif (! grep $_->{amount} == $new_take_profit->{amount}, @take_profit_orders) {
                # Cancel old Take Profit order
                if (@take_profit_orders) {
                    my $o = $take_profit_orders[0];
                    $log->info("Cancel old Take Profit order $o->{order_id}");
                    $exchange->cancelOrder($o->{order_id}, $market);
                }

                # Create new Take Profit order
                $log->info("Create new Take Profit order: $new_take_profit->{price} $new_take_profit->{amount}");
                $exchange->createOrder($new_take_profit->{type}, 
                    {market => $market, price => $new_take_profit->{price}, amount => $new_take_profit->{amount}});
            } else {
                $log->debug("Nothing to do, $pt_type order with amount $new_take_profit->{amount} already exist.");
            }
        } elsif ($analysis->{status} eq 'completed') {
            # Cances all Step orders
            my @step_orders = grep $_->{type} eq $analysis->{side}, @$market_orders;
            foreach my $o (@step_orders) {
                $log->info("Cancel order $o->{order_id}");
                my $rs = $exchange->cancelOrder($o->{order_id}, $market);
            }
        }

        # Create Step orders if trading status is not completed
        if ($analysis->{status} ne 'completed') {
            # Get parameters (Price, Amount and Sum) for new Step orders
            my $new_steps = $self->getStepOrders($analysis, \@trades, $market_orders);
            $log->debug("New Step orders: " . Dumper $new_steps);

            # Create new Step orders
            if (@$new_steps) {
                foreach (@$new_steps) {
                    $log->info("Create new Step ($analysis->{side}) order: $_->{price} $_->{amount}");
                    $exchange->createOrder($analysis->{side},
                        {market => $market, price => $_->{price}, amount => $_->{amount}});
                }
            }
        }

        if ($analysis->{buy}->{sum}) {
            printf("Total Buy (Price, Amount, Sum): %.8f, %.8f, %.8f\n", 
                $analysis->{buy}->{price}, $analysis->{buy}->{amount}, $analysis->{buy}->{sum});
        }
        if ($analysis->{sell}->{sum}) {
            printf("Total Sell (Price, Amount, Sum): %.8f, %.8f, %.8f\n",
                $analysis->{sell}->{price}, $analysis->{sell}->{amount}, $analysis->{sell}->{sum});
        }
        
        printf("\nTake Profit: %d%%, ROI: %d%%", $analysis->{take_profit} * 100, $analysis->{ROI} * 100);
        if ($analysis->{status} eq 'trading') {
            printf(", Break-Even Price: %.8f, Amount Rest: %.8f, Profit/Lost: %.8f\n", 
                $analysis->{break_even_price}, $analysis->{amount_rest}, $analysis->{profit_lost}
            );
            printf("Amount will be earned:\t%.8f", $analysis->{amount_rest} - $new_take_profit->{amount});
        } elsif ($analysis->{status} eq 'completed') {
            printf(", Earned: %.8f (%.2f%%), Profit: %.8f (%.2f%%)", $analysis->{amount_rest},
                $analysis->{amount_rest} * $analysis->{sell}->{price} * (1 - $analysis->{fees}->{maker})
                / $analysis->{buy}->{sum} * 100,
                $analysis->{profit_lost}, $analysis->{profit_lost} / $analysis->{buy}->{sum} * 100
            );
        }
        print "\n\n";

        # Get open orders for market and print
        my $orders = $exchange->getOpenOrders($market);
        my $header = ['OrderID', 'Type', 'Price', 'Amount', 'Filled%', 'Total', 'Date'];
        my $data = [];
        foreach (@$orders) {
            push @$data, [
                $_->{order_id},
                $_->{type},
                $_->{price},
                $_->{amount},
                $_->{filled},
                $_->{total},
                $_->{date},
            ];
        }
        $self->print_table($header, $data) if (scalar @$data);

        # Print history for market
        $header = 
          ['OrderID', 'Market', 'Type', 'Price', 'Amount', 'Fee', 'Total', 'Date', 'TradeID'];
        $data = [];
        foreach (sort {$a->{date} cmp $b->{date}} @trades) {
                push @$data, [
                    $_->{orderNumber},
                    $_->{market},
                    $_->{type},
                    $_->{price},
                    $_->{amount},
                    $_->{fee_all},
                    $_->{total},
                    $_->{date},
                    $_->{tradeID},
                ];
        }
        $self->print_table($header, $data) if (scalar @$data);
    }
}

# Get trade history
sub getTradeHistory ($;$) {
    my $self     = shift;
    my $exchange = shift;
    my $options  = shift;

    my $trades = $exchange->getTradeHistory($options);
    if (ref $trades ne 'HASH') {
        print "No history today\n";
        return;
    }
    $log->debug(Dumper $trades);

    my @trades;
    foreach my $market (keys %$trades) {
        push @trades, map { $_->{market} = $market; $_  } @{ $trades->{$market} };
    }

    my $header = 
      ['OrderID', 'Market', 'Type', 'Price', 'Amount', 'Fee', 'Total', 'Date', 'TradeID'];
    my $data;
    foreach (sort {$a->{date} cmp $b->{date}} @trades) {
            push @$data, [
                $_->{orderNumber},
                $_->{market},
                $_->{type},
                $_->{price},
                $_->{amount},
                $_->{fee_all},
                $_->{total},
                $_->{date},
                $_->{tradeID},
            ];
    }
    $self->print_table($header, $data);
}

# Get all open orders
sub getOpenOrders ($) {
    my $self = shift;
    my $exchange = shift;

    my $rs = $exchange->getOpenOrders();
#    $log->error(Dumper $rs);
    my @markets = grep scalar @{ $rs->{$_} }, sort keys %$rs;
    
    my $header = ['OrderID', 'Type', 'Price', 'Amount', 'Filled%', 'Total', 'Date'];
    my $data;
    foreach my $market (@markets) {
        my $group = {name => $market};  #TODO add current price
        foreach ( @{ $rs->{$market} } ) {
            push @{ $group->{data} }, [
                $_->{order_id},
                $_->{type},
                $_->{price},
                $_->{amount},
                $_->{filled},
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

    $exchange = [$exchange] unless (ref $exchange eq 'ARRAY');

    my $crypto_compare = API::CryptoCompare->new();
    my $btcusd = $crypto_compare->get('price', {fsym => 'BTC', tsyms => 'USD'})->{USD};

    my $grant_total_btc;
    my $header = ['Coin', 'Total', 'Available', 'On Orders', 'BTC Value', 'USD Value', 'Weight'];
    my $data;
    foreach my $e (@$exchange) {
        my $group = {name => $e->name};

        my $balances = $e->getBalances();

        my $total_btc = 0;
        map {$total_btc += $_->{btc_value} if (defined $_->{btc_value})} @$balances;

        foreach (@$balances) {
            push @{ $group->{data} }, [
                $_->{coin},
                $_->{total},
                $_->{available},
                $_->{locked},
                $_->{btc_value},
                sprintf("%.2f", $_->{btc_value} * $btcusd),
                sprintf("%.2f%%", $_->{btc_value}/$total_btc*100),
            ];
        }
        my $invested_usd = get_config_value('invested_usd', $e->name);
        my $invested_btc = get_config_value('invested_btc', $e->name);
        $group->{total} = sprintf("Total Balance: %.2f USD (%.2f%%) / %.8f BTC (%.2f%%)\n", 
            $btcusd * $total_btc, ($btcusd * $total_btc / $invested_usd - 1) * 100,
            $total_btc, ($total_btc / $invested_btc - 1) * 100);
        push @$data, $group;

        $grant_total_btc += $total_btc;
    }

    my $total;
    if (@$exchange > 1) {
        my $grant_total_usd = $btcusd * $grant_total_btc;
        my $invested_usd = get_config_value('invested_usd', 'All');
        my $invested_btc = get_config_value('invested_btc', 'All');
        $total = sprintf("Grant Total Balance: %.2f USD (%.2f%%) / %.8f BTC (%.2f%%), BTC/USD: %.2f\n", 
            $grant_total_usd, ($grant_total_usd / $invested_usd - 1) * 100,
            $grant_total_btc, ($grant_total_btc / $invested_btc - 1) * 100, $btcusd);
    }

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
        print "$group->{total}\n" if ($group->{total});
    }

    print "\n$total\n" if ($total);
}

1;

