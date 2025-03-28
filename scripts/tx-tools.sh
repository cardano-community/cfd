#!/bin/bash

function build-tx {
    echo "Transaction building..."
    if [[ -f $CARDANO_KEYS_DIR/chainbuffer ]]; then
        source $CARDANO_KEYS_DIR/chainbuffer
    else
        CHAINED_UTXO_ID=""
        CHAINED_UTXO_BALANCE=""
    fi

    if ! [ -z "$CHAINED_UTXO_ID" ] && [ ${#CHAINED_UTXO_ID} -eq 64 ]; then
        local IS_TX_IN_MEMPOOL=$(wrap-cli-command is-tx-in-mempool $(echo "$CHAINED_UTXO_ID#0" | cut -d'#' -f1))
        local TX_STATUS=$(echo "$IS_TX_IN_MEMPOOL" | jq -r '.exists')
        if [ "$TX_STATUS" == "false" ]; then
            CHAINED_UTXO_ID=""
            CHAINED_UTXO_BALANCE=""
            rm $CARDANO_KEYS_DIR/chainbuffer     
        fi
    else
      unset CHAINED_UTXO_ID
    fi

    local TX_NAME=$1
    local DEPOSIT=${2:-0}
    local WITHDRAWAL=${3:-0}
    local MIN_UTXO=2000000
    shift 3
    
    if [ $DEPOSIT -gt 0 ]; then
        MIN_UTXO=$(expr $DEPOSIT + $MIN_UTXO)
    fi    

    local CERTIFICATES=("$@")
    local CERTIFICATES=( $(build-arg-array "--certificate-file" "${CERTIFICATES[@]}") )
    
    local CHOSEN_UTXO=("0#0" 0)
    echo "Checking balance..."
    local UTXO_list=$(wrap-cli-command get-utxo-json)      
    local UTXO_hashes=($(echo $UTXO_list | jq -r ". | keys" | jq -r ".[]"))


    if [[ -z "$CHAINED_UTXO_ID" || -z "$CHAINED_UTXO_BALANCE" ]]; then
        for i in "${UTXO_hashes[@]}"
        do
            AMOUNT=$(echo $UTXO_list | jq -r ".[\"$i\"].value.lovelace")
            if [ $AMOUNT -gt ${CHOSEN_UTXO[1]} ]; then
                CHOSEN_UTXO[0]=$i
                CHOSEN_UTXO[1]=$AMOUNT
            fi
        done
    else
        CHOSEN_UTXO[0]=$CHAINED_UTXO_ID
        CHOSEN_UTXO[1]=$CHAINED_UTXO_BALANCE        
    fi

    
    if [ ${CHOSEN_UTXO[1]} -lt $MIN_UTXO ]; then
        echo -e "${BOLD}${BLACK_ON_YELLOW} WARNING! ${NORMAL} Can't process transaction! The balance of the wallet is insufficient. Please, fund it."
        echo -e "There should be at least one UTxO with approximately ${UNDERLINE}$(expr $MIN_UTXO / 1000000) ADA${NORMAL} and no assets:"
        wrap-cli-command get-utxo-pretty
        exit 0
    fi


    local FEE_RAW=$(CARDANO_NODE_SOCKET_PATH=$CARDANO_SOCKET_PATH $CARDANO_BINARIES_DIR/cardano-cli latest transaction build \
        --tx-in "${CHOSEN_UTXO[0]}" \
        $([ "$WITHDRAWAL" -gt 0 ] && echo "--withdrawal $(cat "$CARDANO_KEYS_DIR"/payment/stake.addr)+$WITHDRAWAL") \
        --change-address $(cat "$CARDANO_KEYS_DIR"/payment/base.addr) \
        --out-file "$CARDANO_KEYS_DIR"/"$TX_NAME.raw" \
        "${CERTIFICATES[@]}" \
        "${MAGIC[@]}"
        )

    FEE=${FEE_RAW//[^0-9]/}

    local CHANGE=$((CHOSEN_UTXO[1] - DEPOSIT - FEE + WITHDRAWAL))


    CHAINED_UTXO_BALANCE=$CHANGE
    CHAINED_UTXO_ID="$($CARDANO_BINARIES_DIR/cardano-cli latest transaction txid --tx-file $CARDANO_KEYS_DIR/$TX_NAME.raw)#0"
    
    echo "CHAINED_UTXO_ID='$CHAINED_UTXO_ID'" > $CARDANO_KEYS_DIR/chainbuffer
    echo "CHAINED_UTXO_BALANCE='$CHAINED_UTXO_BALANCE'" >> $CARDANO_KEYS_DIR/chainbuffer
}

function sign-tx {
    echo "Transaction signing..."
    local TX_NAME=$1
    shift
    local SIGN_KEYS=("$@")
    local SIGN_KEYS_PATHS=()

    for key in "${SIGN_KEYS[@]}"; do
        reveal-key "$key"
        SIGN_KEYS_PATHS+=( "$key" )
    done

    trap 'for key in "${SIGN_KEYS_PATHS[@]}"; do hide-key "$key"; done' EXIT

    CARDANO_NODE_SOCKET_PATH=$CARDANO_SOCKET_PATH $CARDANO_BINARIES_DIR/cardano-cli latest transaction sign \
        --tx-body-file $CARDANO_KEYS_DIR/$TX_NAME.raw \
        $(build-arg-array "--signing-key-file" "${SIGN_KEYS[@]}") \
        "${MAGIC[@]}" \
        --out-file $CARDANO_KEYS_DIR/$TX_NAME.signed

    trap - EXIT

    for key in "${SIGN_KEYS_PATHS[@]}"; do
        hide-key "$key"
    done

    rm $CARDANO_KEYS_DIR/$TX_NAME.raw
}



function send-tx {
    echo "Transaction submitting..."
    local TX_NAME=$1

    RESPONSE=$(CARDANO_NODE_SOCKET_PATH=$CARDANO_SOCKET_PATH $CARDANO_BINARIES_DIR/cardano-cli latest transaction submit \
        --tx-file $CARDANO_KEYS_DIR/$TX_NAME.signed \
        "${MAGIC[@]}" 2>&1)
    
    rm $CARDANO_KEYS_DIR/$TX_NAME.signed
    
    if ! echo "$RESPONSE" | grep -q "successfully"; then
        rm $CARDANO_KEYS_DIR/chainbuffer
    fi
    
    if echo $RESPONSE | grep -q "BadInputsUTxO"; then
        echo "Transaction cannot be made at the moment, please wait until the previous transaction is placed in the blockchain."
        return 1
    elif echo $RESPONSE | grep -q "StakeDelegationImpossibleDELEG" || echo $RESPONSE | grep -q "StakeKeyNotRegisteredDELEG"; then
        echo -e "${BOLD}${WHITE_ON_RED} ERROR :${NORMAL} Can't register the pool - your staking key is not registered!" 
        return 1
    else
        echo $RESPONSE
        return 0
    fi    
}
