#!/bin/bash

function wallet-manager {

    echo ""
    echo "***************************************"
    AVAILABLE_ACTIONS=("wallet-create" "wallet-restore" "get-wallet-utxo")

    if [ ! -z "$1" ] && [[ " ${AVAILABLE_ACTIONS[@]} " =~ " $1 " ]]; then
        ACTION_NAME="$1"
    else
        if [ ! -z "$1" ] && [[ ! " ${AVAILABLE_ACTIONS[@]} " =~ " $1 " ]]; then
            echo "Unknown action."
        else
            echo "Action not selected."
        fi

        echo "Available actions:"

        COUNTER=1
        for ACTION in "${AVAILABLE_ACTIONS[@]}"; do
            echo "$COUNTER. $ACTION"
            ((COUNTER++))
        done

        echo -n "Enter the number corresponding to the desired action:"
        read SELECTED_NUM

        if [[ $SELECTED_NUM -ge 1 ]] && [[ $SELECTED_NUM -le ${#AVAILABLE_ACTIONS[@]} ]]; then
            ACTION_NAME="${AVAILABLE_ACTIONS[SELECTED_NUM-1]}"
        else
            echo "Invalid selection. Exiting."
            exit 1
        fi
    fi

    echo "Selected action: $ACTION_NAME"
    $ACTION_NAME
}

function get-keys {
    CADDR=$CARDANO_BINARIES_DIR/cardano-address
    CCLI=$CARDANO_BINARIES_DIR/cardano-cli
    PAYMENT_KEYS_DIR=$CARDANO_KEYS_DIR/payment
    MNEMONIC=$1
    mkdir -p $PAYMENT_KEYS_DIR

    #Root key
    echo $MNEMONIC | $CADDR key from-recovery-phrase Shelley > $PAYMENT_KEYS_DIR/root.xsk

    #Private keys
    $CADDR key child 1852H/1815H/0H/0/0 < $PAYMENT_KEYS_DIR/root.xsk > $PAYMENT_KEYS_DIR/payment.xsk
    $CADDR key child 1852H/1815H/0H/2/0 < $PAYMENT_KEYS_DIR/root.xsk > $PAYMENT_KEYS_DIR/stake.xsk

    #Public keys
    $CADDR key public --with-chain-code < $PAYMENT_KEYS_DIR/payment.xsk > $PAYMENT_KEYS_DIR/payment.xvk
    $CADDR key public --with-chain-code < $PAYMENT_KEYS_DIR/stake.xsk > $PAYMENT_KEYS_DIR/stake.xvk

    #Convertation to cli-format private-keys
    $CCLI key convert-cardano-address-key --shelley-payment-key --signing-key-file $PAYMENT_KEYS_DIR/payment.xsk --out-file $PAYMENT_KEYS_DIR/payment.skey
    $CCLI key convert-cardano-address-key --shelley-stake-key --signing-key-file $PAYMENT_KEYS_DIR/stake.xsk --out-file $PAYMENT_KEYS_DIR/stake.skey

    #Base address building
    $CADDR address payment --network-tag $NETWORK_TAG < $PAYMENT_KEYS_DIR/payment.xvk > $PAYMENT_KEYS_DIR/payment.addr
    $CADDR address delegation $(cat $PAYMENT_KEYS_DIR/stake.xvk) < $PAYMENT_KEYS_DIR/payment.addr > $PAYMENT_KEYS_DIR/base.addr

    rm $PAYMENT_KEYS_DIR/{stake.xsk,payment.xsk,payment.xvk,stake.xvk,payment.addr,root.xsk}

    echo ""
    echo "Done!"
    echo -e "\e[1;30;47mYour keys are stored in:\e[0m \033[1m$PAYMENT_KEYS_DIR\033[0m"
    echo -e "\e[1;30;47mYour payment address is:\e[0m \033[1m$(cat $PAYMENT_KEYS_DIR/base.addr)\033[0m"

    echo "    Be sure that it's funded :)"
    echo "    Just send some ADA to the address above;"
    echo -e "    You can also get some free \033[1mtestnet ADA\033[0m with https://docs.cardano.org/cardano-testnet/tools/faucet;"
    echo "    Remember, the Faucet works only within the official testnets!"
    echo ""

    for FILE in $(find $CARDANO_KEYS_DIR -type f); do
        chmod 0600 $FILE
    done
    return 0
}

function wallet-create {
    if rewriting-prompt "$CARDANO_KEYS_DIR/payment/payment.skey" "You are about to irreversibly delete an existing wallet!"; then
        CADDR=$CARDANO_BINARIES_DIR/cardano-address
        MNEMONIC_PATH=$CARDANO_KEYS_DIR/mnemonic.txt
        MNEMONIC=$($CADDR recovery-phrase generate)

        echo $MNEMONIC > $MNEMONIC_PATH
        chmod 0400 $MNEMONIC_PATH
        get-keys "$MNEMONIC"

        echo ""
        echo -e "\e[1;30;47mHere is a file with your recovery phrase\e[0m: \033[1m$MNEMONIC_PATH\033[0m"
        echo "    1) Never share it;"
        echo -e "    2) Move it to the safe storage or better \033[1mwrite to paper and remove the file\033[0m;"
        echo "    3) Keep it secured;"
        echo -e "    4) Rememeber - \033[1mif tou lose it, you lose access to your wallet\033[0m..."
        echo ""
    fi
}

function wallet-restore {
    if rewriting-prompt "$CARDANO_KEYS_DIR/payment/payment.skey" "You are about to irreversibly delete an existing wallet!"; then
        tput reset
        read -p "Enter 24w mnemonic: " MNEMONIC
        tput reset

        get-keys "$MNEMONIC"
    fi
}

function get-wallet-utxo {
    wrap-cli-command get-utxo-pretty
}
