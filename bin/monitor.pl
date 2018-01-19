#!/usr/bin/env perl -w
##!/usr/bin/perl -w
#===============================================================================
#
#         FILE: monitor.pl
#
#        USAGE: perl5.20.2 ~/ubs/tmp/Crypto/bin/monitor.pl
#               perl ~/projects/Crypto/bin/monitor.pl
#
#  DESCRIPTION: 
#
#      OPTIONS: ---
# REQUIREMENTS: ---
#         BUGS: ---
#        NOTES: ---
#       AUTHOR: Charmarder
# ORGANIZATION: HeadStudio
#      VERSION: 1.0
#      CREATED: 1/10/2018 7:25:03 PM
#      CHANGED: $Date$
#   CHANGED BY: $Author$
#     REVISION: $Rev$
#===============================================================================

use FindBin qw($Bin $Script);
BEGIN {
    $ENV{ROOT_DIR} = "$Bin/..";
    chdir $Bin;

    delete $ENV{PERL5LIB} if exists $ENV{PERL5LIB};

    # Location of application libraries.
    map { unshift @INC, $_ } reverse('.', "$ENV{ROOT_DIR}/lib");
}

use strict;
use warnings;
use utf8;
use Data::Dumper;

use Util::Config;
use Util::Logger qw($log);

use Log::Log4perl::Level;
use JSON;

use API::Poloniex;
use Strategy::BuyLowSellHigh;

############################################################################### 
# Initial configuration
#
# get global configuration from file
$GO->{CFG} = &Util::Config::get_config({ConfigFile => 'Crypto.conf'});
# init logger
$log = Util::Logger->init_once({}, $GO->{CFG});

############################################################################### 
# Definition of the input parameters
#
$GO->{SCRIPT} = {
    description => [
        "Usage: $Script [OPTIONS]",
        "$Script --Command <command> --parameter <value>...",
    ],
    options     => {
        'help|?' => {
            info    => 'Show this screen.',
            default => sub {print &Util::Config::help; exit 0},
        },
        'debug|d' => {
            info    => 'Debug mode.',
            default => 0,
        },
        'exchange|e=s' => {
            info      => 'Name of exchange',
            default   => 'Poloniex',
            pattern   => '/^Poloniex$/',
        },
        'command|c=s' => {
            info      => 'Name of command',
            mandatory => 1,
            default   => 'returnCompleteBalances',
        },
        'currencyPair=s' => {
            info      => 'Currency pair',
        },
        'start=s' => {
            info      => 'Start date',
        },
        'end=s' => {
            info      => 'End date',
        },
        'startPrice=s' => {
            info      => 'Start Price',
        },
        'run' => {
            info    => 'Run trading order',
            default => 0,
        },
    },
    examples    => [
        "$Script --Exchange Poloniex --Command returnCompleteBalances",
        "$Script --Exchange Poloniex --Command returnOpenOrders",
        "$Script --Exchange Poloniex --Command returnTradeHistory",
        "$Script --Exchange Poloniex --Command returnTradeHistory --CurrencyPair BTC_BCN --Start '2018-01-09'",
        "$Script --Exchange Poloniex --Command calculateOrderList",
    ],
};


###############################################################################
# MAIN TESTS START HERE
###############################################################################
my $options = Util::Config::get_options($GO->{SCRIPT});

$options->{currencyPair} =~ s/(\w+)\/(\w+)/$2_$1/ if ($options->{currencyPair});

$log->level($DEBUG) if ($options->{debug});
$log->debug("$Script called. Options are:\n" . Dumper($options));

# Dispatching
if ($options->{exchange} eq 'Poloniex') {
    my $poloniex = API::Poloniex->new();
    my $strategy = Strategy::BuyLowSellHigh->new();

    if ($options->{command} eq 'returnCompleteBalances') {
        $poloniex->returnCompleteBalances();
    } elsif ($options->{command} eq 'returnOpenOrders') {
        $poloniex->returnOpenOrders();
    } elsif ($options->{command} eq 'returnTradeHistory') {
        $poloniex->returnTradeHistory($options);
    } elsif ($options->{command} eq 'calculateOrderList') {
        Util::Config::usage('Start Price must be defined') if (!$options->{startPrice});
        $strategy->calculateOrderList($options->{startPrice});
    } else {
        die("Unsupported command\n");
    }
} else {
    die("Unsupported exchange\n");
}

###############################################################################

