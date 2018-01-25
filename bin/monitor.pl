#!/usr/bin/perl -w
##!/usr/bin/env perl -w
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
$GO->{CFG} = &Util::Config::get_config();
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
            default   => 'poloniex',
            pattern   => '/^poloniex$/',
        },
        'command|c=s' => {
            info      => 'Name of command',
            mandatory => 1,
            default   => 'balances',
        },
        'market=s' => {
            info      => 'Currency pair',
        },
        'start=s' => {
            info      => 'Start date',
        },
        'end=s' => {
            info      => 'End date',
        },
        'start-price=s' => {
            info      => 'Start Price',
        },
        'run' => {
            info    => 'Run trading order',
            default => 0,
        },
    },
    examples    => [
        "$Script -e poloniex -c balances",
        "$Script -e poloniex -c orders",
        "$Script -e poloniex -c history -m BTC_BCN --start '2018-01-09'",
        "$Script -e poloniex -c trade",
        "$Script -e poloniex -c list",
    ],
};


###############################################################################
# MAIN TESTS START HERE
###############################################################################
my $options = Util::Config::get_options($GO->{SCRIPT});

$options->{market} =~ s/(\w+)\/(\w+)/$2_$1/ if ($options->{market});

$log->level($DEBUG) if ($options->{debug});
$log->debug("$Script called. Options are:\n" . Dumper($options));

my $exchange;
if ($options->{exchange} eq 'poloniex') {
    $exchange = API::Poloniex->new();
} else {
    die("Unsupported exchange\n");
}

# Dispatching
my $strategy = Strategy::BuyLowSellHigh->new();
if ($options->{command} eq 'balances') {
    $strategy->getBalances($exchange);
} elsif ($options->{command} eq 'orders') {
    $strategy->getOpenOrders($exchange);
} elsif ($options->{command} eq 'history') {
    $strategy->getTradeHistory($exchange, $options);
} elsif ($options->{command} eq 'trade') {
    $strategy->trade($exchange, $options);
} elsif ($options->{command} eq 'list') {
    Util::Config::usage('Start Price must be defined') if (!$options->{'start-price'});
    $strategy->calculateOrderList($options->{'start-price'});
} else {
    die("Unsupported command\n");
}

###############################################################################

