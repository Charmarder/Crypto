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


# Calculate Buy/Sell Average Price, Total Amount and Toral Sum, as well Amount Rest and Profit/Lost
sub getAnalysis ($$) {
    my $self     = shift;
    my $market   = shift;
    my $trades   = shift;
    my $exchange = shift;

    my $analysis = {
        market => $market,
        buy    => {
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
        take_profit => get_config_value('TakeProfit', $market),
        ROI         => get_config_value('ROI', $market),
        fees        => $exchange->getFees(),
        precisions  => $exchange->getPrecision($market),
    };

    foreach (@$trades) {
        if ($_->{type} eq 'buy') {
            $analysis->{buy}->{amount} += $_->{amount} * (1 - $_->{fee});
            $analysis->{buy}->{sum} += $_->{amount} * $_->{price};
        } elsif ($_->{type} eq 'sell') {
            $analysis->{sell}->{amount} += $_->{amount};
            $analysis->{sell}->{sum} += $_->{amount} * $_->{price} * (1 - $_->{fee});
            $analysis->{sell}->{sum_with_fee} += $_->{amount} * $_->{price};
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
    my $analysis  = shift;

    my $buy_price   = $analysis->{buy}->{price};
    my $buy_sum     = $analysis->{buy}->{sum};
    my $sell_sum    = $analysis->{sell}->{sum};
    my $take_profit = $analysis->{take_profit};
    my $ROI         = $analysis->{ROI};

    my $precision_price  = $analysis->{precisions}->{price};
    my $precision_amount = $analysis->{precisions}->{amount};

    my $new_sell;

    $new_sell->{price} = $buy_price * (1 + $take_profit);
    $new_sell->{sum} = ($buy_sum * (1 + $ROI) - $sell_sum)  / (1 - $analysis->{fees}->{maker});
    $new_sell->{amount} = sprintf("%.${precision_amount}f", $new_sell->{sum} / $new_sell->{price});
    $new_sell->{price} = sprintf("%.${precision_price}f", $new_sell->{price});

    return $new_sell;
}

# Return parameters for new buy orders
sub calculateBuy ($$$) {
    my $self     = shift;
    my $analysis = shift;
    my $trades   = shift;
    my $orders   = shift;

    my $market = $analysis->{market};

    my $buy_orders = [grep $_->{type} eq 'buy', @$orders];
    my $new_buy;

    return [] if (@$buy_orders > 2);

    # Find Start Price and Start Amount
    my ($start_price, $start_amount);
    foreach (sort {$a->{date} cmp $b->{date}} grep $_->{type} eq 'buy', @$trades) {
        if (! defined $start_price) {
            $start_price = $_->{price};
            $start_amount = $_->{amount};
        } elsif ($start_price == $_->{price}) {
            $start_amount += $_->{amount};
        } else {
            last;
        }
    }
    $log->debug("Start Price and Amount: $start_price, $start_amount");

    # Сalculate array of buy orders
    my @buys;
    my $price_step = get_config_value('PriceStep', $market);
    my $amount_step = get_config_value('AmountStep', $market);
    my $max_steps = int(50/($price_step*100));
    my $precision_price  = $analysis->{precisions}->{price};
    my $precision_amount = $analysis->{precisions}->{amount};
    for (my $i = 0; $i < $max_steps; $i++) {
        my $price = $start_price * (1 -  $price_step * $i);
        my $amount = $start_amount * (1 + $amount_step) ** $i;
        push @buys, {
            market => $market,
            price  => sprintf("%.${precision_price}f", $price),
            amount => sprintf("%.${precision_amount}f", $amount),
        };
    }

    # Find last buy from history or orders
    my $last_order;
    if (@$buy_orders) {
        $last_order = [sort {$a->{price} cmp $b->{price}} @$buy_orders]->[0];
    } else {
        $last_order  = [sort {$b->{date} cmp $a->{date}} grep $_->{type} eq 'buy', @$trades]->[0];
    }
    $log->debug(Dumper $last_order);

    # Grep not created orders
    my $not_created = [grep $_->{price} < $last_order->{price}, @buys];

    my $max_orders = get_config_value('MaxBuyOrders', $market);
    my $num = ($max_orders - @$buy_orders > @$not_created) ? @$not_created - 1 : $max_orders - 1 - @$buy_orders;
    @$new_buy = (grep $_->{price} < $last_order->{price}, @buys)[0..$num];

    return $new_buy;
}

# Analysis and trade
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

        next unless scalar @trades;

        print '-' x length($market) . "\n$market\n" . '-' x length($market) . "\n";

        my $analysis = $self->getAnalysis($market, \@trades, $exchange);
        $log->debug(Dumper $analysis);

        my $new_sell;
        if ($analysis->{profit_lost} < 0) {
            # Get parameters for new sell order (Price, Amount and Sum)
            $new_sell = $self->calculateSell($analysis);
            $log->debug(Dumper $new_sell);

            # Step 1: Cancel old sell order if exist and create new one if not exist
            my $market_orders = $orders->{$market};
            my $new_amount = $new_sell->{amount};
            if (! grep $_->{type} eq 'sell' && $_->{amount} == $new_sell->{amount}, @$market_orders) {
                # Be sure that there is no more then one sell order
                my @sell_orders = grep $_->{type} eq 'sell', @$market_orders;
                if (@sell_orders > 1) {
                    $log->warn('Cannot do anythig, there are more then one sell orders.');
                } else {
                    if (@sell_orders) {
                        # Cancel old sell order
                        my $o = $sell_orders[0];
                        $log->info("Cancel old Sell order $o->{order_id}");
                        $exchange->cancelOrder($o->{order_id}, $market);
                    }

                    # Create new Sell order
                    $log->info("Create new Sell order: $new_sell->{price} $new_sell->{amount}");
                    $exchange->createOrder('sell', 
                        {market => $market, price => $new_sell->{price}, amount => $new_sell->{amount}});
                }
            } else {
                $log->debug("Nothing to do, sell order with amount $new_sell->{amount} already exist.");
            }

            # Get parameters for new buy order (Price, Amount and Sum)
            my $new_buy = $self->calculateBuy($analysis, \@trades, $market_orders);
            $log->debug(Dumper $new_buy);

            # Step 2: Create new buy orders
            if (@$new_buy) {
                foreach (@$new_buy) {
                    $log->info("Create new Buy order: $_->{price} $_->{amount}");
                    $exchange->createOrder('buy', {market => $market, price => $_->{price}, amount => $_->{amount}});
                }
            }
        } else {
            # Cances all orders
            foreach my $o (@{ $orders->{$market} }) {
                $log->info("Cancel order $o->{order_id}");
                my $rs = $exchange->cancelOrder($o->{order_id}, $market);
            }
        }


        if ($analysis->{buy}->{sum}) {
            printf("Total Buy (Price Amount Sum): %.8f, %.8f, %.8f\n", 
                $analysis->{buy}->{price}, $analysis->{buy}->{amount}, $analysis->{buy}->{sum});
        }
        if ($analysis->{sell}->{sum}) {
            printf("Total Sell (Price Amount Sum): %.8f, %.8f, %.8f\n",
                $analysis->{sell}->{price}, $analysis->{sell}->{amount}, $analysis->{sell}->{sum_with_fee});
        }
        
        my $msg = ($analysis->{profit_lost} > 0) ? 'You have earned' : 'Amount Rest';
        printf("Take Profit: %d%%, ROI: %d%%, $msg: %.8f, Profit/Lost: %.8f\n\n", 
            $analysis->{take_profit} * 100, $analysis->{ROI} * 100,
            $analysis->{amount_rest}, $analysis->{profit_lost}
        );

        if ($analysis->{profit_lost} < 0) {
            printf("Amount will be earned:\t%.8f\n\n", $analysis->{amount_rest} - $new_sell->{amount});
        }

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
        $self->print_table($header, $data);
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

