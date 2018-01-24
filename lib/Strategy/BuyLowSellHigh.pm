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
sub calculateTotal {
    my $self         = shift;
    my $transactions = shift;

    my $total = {
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
    };

    foreach (@$transactions) {
        if ($_->{type} eq 'buy') {
            $total->{buy}->{amount} += $_->{amount} * (1 - $_->{fee});
            $total->{buy}->{sum} += $_->{amount} * $_->{rate};
        } elsif ($_->{type} eq 'sell') {
            $total->{sell}->{amount} += $_->{amount};
            $total->{sell}->{sum} += $_->{amount} * $_->{rate} * (1 - $_->{fee});
            $total->{sell}->{sum_with_fee} += $_->{amount} * $_->{rate};
        }
    }

    if ($total->{buy}->{sum}) {
        $total->{buy}->{price} = $total->{buy}->{sum} / $total->{buy}->{amount};
    }
    if ($total->{sell}->{sum}) {
        $total->{sell}->{price} = $total->{sell}->{sum} / $total->{sell}->{amount};
    }
    $total->{amount_rest} = $total->{buy}->{amount} - $total->{sell}->{amount};
    $total->{profit_lost} = $total->{sell}->{sum} - $total->{buy}->{sum};

    return $total;
}

# Return parameters for new sell order
sub calculateSell {
    my $self          = shift;
    my $currency_pair = shift;
    my $buy_price     = shift;
    my $buy_sum       = shift;
    my $sell_sum      = shift;

    my $new_sell;

    my $take_profit = get_config_value('TakeProfit', $currency_pair);
    my $ROI = get_config_value('ROI');

    $new_sell->{price} = $buy_price * (1 + $take_profit);
    $new_sell->{sum} = ($buy_sum * (1 + $ROI) - $sell_sum)  / 0.9985;
    $new_sell->{amount} = $new_sell->{sum} / $new_sell->{price};

    return $new_sell;
}

# Get trade history
sub getTradeHistory ($;$) {
    my $self     = shift;
    my $exchange = shift;
    my $options  = shift;


    my $rs = $exchange->getTradeHistory($options);

    my @transactions; 
    if (! defined $options->{'currency-pair'}) {
        foreach my $market (keys %$rs) {
            push @transactions, map { $_->{market} = $market; $_  } @{ $rs->{$market} };
        }
    } else {
        my $currency_pair = $options->{'currency-pair'};

        push @transactions, map { $_->{market} = $currency_pair; $_  } @$rs;

        my $total = $self->calculateTotal(\@transactions);

        if ($total->{buy}->{sum}) {
            printf("Total Buy (Price Amount Sum):\t%.8f\t%.8f\t%.8f\n", 
                $total->{buy}->{price}, $total->{buy}->{amount}, $total->{buy}->{sum});
        }
        if ($total->{sell}->{sum}) {
            printf("Total Sell (Price Amount Sum):\t%.8f\t%.8f\t%.8f\n",
                $total->{sell}->{price}, $total->{sell}->{amount}, $total->{sell}->{sum_with_fee});
        }
        
        my $msg = ($total->{profit_lost} > 0) ? 'You have earned' : 'Amount Rest';
        printf("$msg:\t%.8f\tProfit/Lost:\t%.8f\n\n", $total->{amount_rest}, $total->{profit_lost});

        # Recomended Sell Price, Amount and Sum
        if ($total->{profit_lost} < 0) {
            my $take_profit = get_config_value('TakeProfit', $currency_pair);
            my $ROI = get_config_value('ROI');
            my $new_sell = $self->calculateSell($currency_pair, $total->{buy}->{price}, $total->{buy}->{sum}, $total->{sell}->{sum});

            printf("Recomended Sell +" . $take_profit * 100 . '%% ROI ' . $ROI * 100 . '%%' .
                " (Price Amount Sum):\t%.8f\t%.8f\t%.8f\n",
                $new_sell->{price}, $new_sell->{amount}, $new_sell->{sum});
            printf("Amount will be earned:\t%.8f\n\n", $total->{amount_rest} - $new_sell->{amount});

            # Get open orders for currentPair
            my $orders = $exchange->poloniex_trading_api( 'returnOpenOrders', { currencyPair => $currency_pair } );

            $new_sell->{amount} = sprintf("%.8f", $new_sell->{amount});
            if (! grep $_->{type} eq 'sell' && $_->{amount} == $new_sell->{amount}, @$orders) {
                # Cancel old sell orders
                for my $o (grep $_->{type} eq 'sell', @$orders) {
                    $rs = $exchange->poloniex_trading_api('cancelOrder', { orderNumber => $o->{orderNumber} });
                    $log->info(Dumper $rs) if $rs;
                }

                # Place new sell order
                my $new_sell_order_params = {
                    currencyPair => $currency_pair,
                    rate         => sprintf("%.8f", $new_sell->{price} ),
                    amount       => $new_sell->{amount},
                    postOnly     => 1,
                };
                $log->info("New Sell order parameters: " . Dumper $new_sell_order_params);
                $rs = $exchange->poloniex_trading_api('sell', $new_sell_order_params);
                $log->info(Dumper $rs) if $rs;
            } else {
                $log->debug('Nothing to do, sell order already exist.');
            }
        }

        # Get open orders for currentPair
        my $orders = $exchange->poloniex_trading_api( 'returnOpenOrders', { currencyPair => $currency_pair } );
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


# Get all open orders
sub getOpenOrders ($) {
    my $self = shift;
    my $exchange = shift;

    my ($header, $data) = $exchange->getOpenOrders();
    
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

