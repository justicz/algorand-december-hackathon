#!/bin/bash

date '+dynamic-fee-teal-test start %Y%m%d_%H%M%S'

set -e
set -x
set -o pipefail

export GOPATH=$(go env GOPATH)

TEMPDIR=$(mktemp -d)
trap "rm -rf $TEMPDIR" 0

NETDIR=${TEMPDIR}/net

if [ ! -z $BINDIR ]; then
    export PATH=${BINDIR}:${PATH}
fi

goal network create -r ${NETDIR} -n dynamic-fee-teal-test -t ${GOPATH}/src/github.com/algorand/go-algorand/test/testdata/nettemplates/TwoNodes50Each.json

goal network start -r ${NETDIR}

trap "goal network stop -r ${NETDIR}; rm -rf ${TEMPDIR}" 0

export ALGORAND_DATA=${NETDIR}/Node

ACCOUNT=$(goal account list|awk '{ print $3 }')
ACCOUNTB=$(goal account new|awk '{ print $6 }')
ACCOUNTC=$(goal account new|awk '{ print $6 }')
ORACLE=$(algokey generate -f ${TEMPDIR}/oracle.key | grep "Public key" | awk '{ print $3 }')
ZERO_ADDRESS=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAY5HFKQ

# Fund ACCOUNTB and ACCOUNTC
goal clerk send -a 1000000000 -f ${ACCOUNT} -t ${ACCOUNTB}
goal clerk send -a 1000000000 -f ${ACCOUNT} -t ${ACCOUNTC}

TOTALASSETS=10000000000

# Create YES asset
YESIDX=$(goal asset create --creator ${ACCOUNT} --name YES_TOKEN --total ${TOTALASSETS} | tail -n 1 | awk '{ print $6 }')

# Create NO asset
NOIDX=$(goal asset create --creator ${ACCOUNT} --name NO_TOKEN --total ${TOTALASSETS} | tail -n 1 | awk '{ print $6 }')

###
### Create pool contract
###

# These are the statements to be signed by the oracle if yes/no wins
YESSTMT=Y29udGVzdC0wLXllcw==
NOSTMT=Y29udGVzdC0wLW5v

algotmpl -d templates/ pool --init_start_rnd=1 --init_end_rnd=1001 --max_self_fee=1000 --no_asset=${NOIDX} --yes_asset=${YESIDX} --no_stmt=${NOSTMT} --yes_stmt=${YESSTMT} --oracle=${ORACLE} > ${TEMPDIR}/pool.teal

# Compile pool contract
POOLADDR=$(goal clerk compile ${TEMPDIR}/pool.teal -o ${TEMPDIR}/pool.tealc | awk '{ print $2 }')

# Transfer pool contract a small balance for asset slot allocation and minbalance
goal clerk send -a 302000 -f ${ACCOUNT} -t ${POOLADDR}

###
### Pool contract self-transfer setup
###

# Do pool contract self-transfer to allocate slots for YESIDX and NOIDX
goal asset send -a 0 --assetid ${YESIDX} -f ${POOLADDR} --firstvalid=1 --lastvalid=1001 --fee=1000 -x WUVTTEVBU0VBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE= -t ${POOLADDR} -o ${TEMPDIR}/pool-asset-self-yes.txn
goal asset send -a 0 --assetid ${NOIDX} -f ${POOLADDR} --firstvalid=1 --lastvalid=1001 --fee=1000 -x Tk9MRUFTRUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE= -t ${POOLADDR} -o ${TEMPDIR}/pool-asset-self-no.txn

# Group the self-transfers together
cat ${TEMPDIR}/pool-asset-self-yes.txn ${TEMPDIR}/pool-asset-self-no.txn > ${TEMPDIR}/pool-asset-self-txns-nogroup.txn
goal clerk group -i ${TEMPDIR}/pool-asset-self-txns-nogroup.txn -o ${TEMPDIR}/pool-asset-self-txns-group.txn
goal clerk split -i ${TEMPDIR}/pool-asset-self-txns-group.txn -o ${TEMPDIR}/pool-asset-self-txns-to-be-signed.txn

# Sign the self-transfers with the logic sig
goal clerk sign -p ${TEMPDIR}/pool.teal -i ${TEMPDIR}/pool-asset-self-txns-to-be-signed-0.txn -o ${TEMPDIR}/pool-asset-self-txns-0.stxn
goal clerk sign -p ${TEMPDIR}/pool.teal -i ${TEMPDIR}/pool-asset-self-txns-to-be-signed-1.txn -o ${TEMPDIR}/pool-asset-self-txns-1.stxn
cat ${TEMPDIR}/pool-asset-self-txns-0.stxn ${TEMPDIR}/pool-asset-self-txns-1.stxn > ${TEMPDIR}/pool-asset-txns-to-bcast.stxn

# Send the signed self-transfers
goal clerk rawsend -f ${TEMPDIR}/pool-asset-txns-to-bcast.stxn

###
### Create bid contract
###

algotmpl -d templates/ bid --init_start_rnd=1 --init_end_rnd=1001 --max_self_fee=1000 --no_asset=${NOIDX} --yes_asset=${YESIDX} --pool=${POOLADDR} > ${TEMPDIR}/bid.teal

# Compile bid contract
BIDADDR=$(goal clerk compile ${TEMPDIR}/bid.teal -o ${TEMPDIR}/bid.tealc | awk '{ print $2 }')

# Transfer bid contract a small balance for asset slot allocation and minbalance
goal clerk send -a 302000 -f ${ACCOUNT} -t ${BIDADDR}

###
### bid contract self-transfer setup
###

# Do bid contract self-transfer to allocate slots for YESIDX and NOIDX
goal asset send -a 0 --assetid ${YESIDX} -f ${BIDADDR} --firstvalid=1 --lastvalid=1001 --fee=1000 -x WUVTTEVBU0VBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE= -t ${BIDADDR} -o ${TEMPDIR}/bid-asset-self-yes.txn
goal asset send -a 0 --assetid ${NOIDX} -f ${BIDADDR} --firstvalid=1 --lastvalid=1001 --fee=1000 -x Tk9MRUFTRUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE= -t ${BIDADDR} -o ${TEMPDIR}/bid-asset-self-no.txn

# Group the self-transfers together
cat ${TEMPDIR}/bid-asset-self-yes.txn ${TEMPDIR}/bid-asset-self-no.txn > ${TEMPDIR}/bid-asset-self-txns-nogroup.txn
goal clerk group -i ${TEMPDIR}/bid-asset-self-txns-nogroup.txn -o ${TEMPDIR}/bid-asset-self-txns-group.txn
goal clerk split -i ${TEMPDIR}/bid-asset-self-txns-group.txn -o ${TEMPDIR}/bid-asset-self-txns-to-be-signed.txn

# Sign the self-transfers with the logic sig
goal clerk sign -p ${TEMPDIR}/bid.teal -i ${TEMPDIR}/bid-asset-self-txns-to-be-signed-0.txn -o ${TEMPDIR}/bid-asset-self-txns-0.stxn
goal clerk sign -p ${TEMPDIR}/bid.teal -i ${TEMPDIR}/bid-asset-self-txns-to-be-signed-1.txn -o ${TEMPDIR}/bid-asset-self-txns-1.stxn
cat ${TEMPDIR}/bid-asset-self-txns-0.stxn ${TEMPDIR}/bid-asset-self-txns-1.stxn > ${TEMPDIR}/bid-asset-txns-to-bcast.stxn

# Send the signed self-transfers
goal clerk rawsend -f ${TEMPDIR}/bid-asset-txns-to-bcast.stxn

###
### Fund the bid contract
###

goal asset send -a ${TOTALASSETS} --assetid ${YESIDX} -f ${ACCOUNT} -t ${BIDADDR}
goal asset send -a ${TOTALASSETS} --assetid ${NOIDX} -f ${ACCOUNT} -t ${BIDADDR}

###
### Accounts B and C are going to bet Yes and No, respectively.
###

# Allocate space for yes asset in ACCOUNTB and no asset in ACCOUNTC
goal asset send -a 0 --assetid ${YESIDX} -f ${ACCOUNTB} -t ${ACCOUNTB}
goal asset send -a 0 --assetid ${NOIDX} -f ${ACCOUNTC} -t ${ACCOUNTC}

# Txns 1 and 2: paying for yes assets and no assets. Yes costs .2 algos/token, No costs .8 algos/token
# So ACCOUNTB receives 10 Yes tokens, and ACCOUNTC receives 10 No tokens
goal clerk send -a 2000000 -f ${ACCOUNTB} -t ${POOLADDR} -o ${TEMPDIR}/bid-0.txn
goal clerk send -a 8000000 -f ${ACCOUNTC} -t ${POOLADDR} -o ${TEMPDIR}/bid-1.txn

# Txns 3 and 4: pay the fee for the asset xfer of the tokens from the bid contract
goal clerk send -a 1234 -f ${ACCOUNTB} -t ${BIDADDR} -o ${TEMPDIR}/bid-2.txn
goal clerk send -a 1234 -f ${ACCOUNTC} -t ${BIDADDR} -o ${TEMPDIR}/bid-3.txn

# Txns 4 and 5: do the asset xfer of yes token to ACCOUNTB and no token to ACCOUNTC
goal asset send -a 10 --assetid ${YESIDX} -f ${BIDADDR} -t ${ACCOUNTB} --fee=1234 -o ${TEMPDIR}/bid-4.txn
goal asset send -a 10 --assetid ${NOIDX} -f ${BIDADDR} -t ${ACCOUNTC} --fee=1234 -o ${TEMPDIR}/bid-5.txn

# Group the transactions together
cat ${TEMPDIR}/bid-0.txn ${TEMPDIR}/bid-1.txn ${TEMPDIR}/bid-2.txn ${TEMPDIR}/bid-3.txn ${TEMPDIR}/bid-4.txn ${TEMPDIR}/bid-5.txn > ${TEMPDIR}/bid-txns-nogroup.txn
goal clerk group -i ${TEMPDIR}/bid-txns-nogroup.txn -o ${TEMPDIR}/bid-txns-group.txn
goal clerk split -i ${TEMPDIR}/bid-txns-group.txn -o ${TEMPDIR}/bid-txns-to-be-signed.txn

# Sign each txn
goal clerk sign -i ${TEMPDIR}/bid-txns-to-be-signed-0.txn -o ${TEMPDIR}/bid-txns-0.stxn
goal clerk sign -i ${TEMPDIR}/bid-txns-to-be-signed-1.txn -o ${TEMPDIR}/bid-txns-1.stxn
goal clerk sign -i ${TEMPDIR}/bid-txns-to-be-signed-2.txn -o ${TEMPDIR}/bid-txns-2.stxn
goal clerk sign -i ${TEMPDIR}/bid-txns-to-be-signed-3.txn -o ${TEMPDIR}/bid-txns-3.stxn
goal clerk sign -p ${TEMPDIR}/bid.teal -i ${TEMPDIR}/bid-txns-to-be-signed-4.txn -o ${TEMPDIR}/bid-txns-4.stxn
goal clerk sign -p ${TEMPDIR}/bid.teal -i ${TEMPDIR}/bid-txns-to-be-signed-5.txn -o ${TEMPDIR}/bid-txns-5.stxn
cat ${TEMPDIR}/bid-txns-0.stxn ${TEMPDIR}/bid-txns-1.stxn ${TEMPDIR}/bid-txns-2.stxn ${TEMPDIR}/bid-txns-3.stxn ${TEMPDIR}/bid-txns-4.stxn ${TEMPDIR}/bid-txns-5.stxn > ${TEMPDIR}/bid-txns-to-bcast.stxn

# Send the signed bid group
goal clerk rawsend -f ${TEMPDIR}/bid-txns-to-bcast.stxn

# List balances
goal account list

###
### There was a winner! Have the oracle sign YESSTMT
###

echo ${YESSTMT} | base64 -d > ${TEMPDIR}/yesstmt.bin

ORACLESIG=$(dsign ${TEMPDIR}/oracle.key ${TEMPDIR}/pool.tealc ${TEMPDIR}/yesstmt.bin)

###
### Have ACCOUNTB cash out their 10 algos for their 10 yes tokens
###

# Txn 1: transfer our 10 yes tokens to the pool contract
goal asset send -a 10 --assetid ${YESIDX} -f ${ACCOUNTB} -t ${POOLADDR} -o ${TEMPDIR}/redeem-0.txn

# Txn 2: pay fee for transfer of algos from POOLADDR to ACCOUNTB
goal clerk send -a 1234 -f ${ACCOUNTB} -t ${POOLADDR} -o ${TEMPDIR}/redeem-1.txn

# Txn 3: transfer 10 algos from POOLADDR to ACCOUNTB, notes will be YESSTMT
goal clerk send -a 10000000 -f ${POOLADDR} -t ${ACCOUNTB} --noteb64=${YESSTMT} --fee=1234 -o ${TEMPDIR}/redeem-2.txn

# Group the transactions together
cat ${TEMPDIR}/redeem-0.txn ${TEMPDIR}/redeem-1.txn ${TEMPDIR}/redeem-2.txn > ${TEMPDIR}/redeem-txns-nogroup.txn
goal clerk group -i ${TEMPDIR}/redeem-txns-nogroup.txn -o ${TEMPDIR}/redeem-txns-group.txn
goal clerk split -i ${TEMPDIR}/redeem-txns-group.txn -o ${TEMPDIR}/redeem-txns-to-be-signed.txn

# Sign each txn, arg_0 of redemption xfer will be signed oracle statement
goal clerk sign -i ${TEMPDIR}/redeem-txns-to-be-signed-0.txn -o ${TEMPDIR}/redeem-txns-0.stxn
goal clerk sign -i ${TEMPDIR}/redeem-txns-to-be-signed-1.txn -o ${TEMPDIR}/redeem-txns-1.stxn
goal clerk sign -p ${TEMPDIR}/pool.teal --argb64 ${ORACLESIG} -i ${TEMPDIR}/redeem-txns-to-be-signed-2.txn -o ${TEMPDIR}/redeem-txns-2.stxn
cat ${TEMPDIR}/redeem-txns-0.stxn ${TEMPDIR}/redeem-txns-1.stxn ${TEMPDIR}/redeem-txns-2.stxn > ${TEMPDIR}/redeem-txns-to-bcast.stxn

# Send the signed redemption group
goal clerk rawsend -f ${TEMPDIR}/redeem-txns-to-bcast.stxn

# List balances
goal account list
