#!/bin/bash
#
# Copyright IBM Corp. All Rights Reserved.
#
# SPDX-License-Identifier: Apache-2.0
#
export PATH=./bin:${PWD}:$PATH
export FABRIC_CFG_PATH=${PWD}
export VERBOSE=false

function dkcl(){
        CONTAINER_IDS=$(docker ps -aq)
	echo
        if [ -z "$CONTAINER_IDS" -o "$CONTAINER_IDS" = " " ]; then
                echo "========== No containers available for deletion =========="
        else
                docker rm -f $CONTAINER_IDS
        fi
	echo
}

function dkrm(){
        DOCKER_IMAGE_IDS=$(docker images | grep "dev\|none\|test-vp\|peer[0-9]-" | awk '{print $3}')
	echo
        if [ -z "$DOCKER_IMAGE_IDS" -o "$DOCKER_IMAGE_IDS" = " " ]; then
		echo "========== No images available for deletion ==========="
        else
                docker rmi -f $DOCKER_IMAGE_IDS
        fi
	echo
}

function restartNetwork() {
	echo

  #teardown the network and clean the containers and intermediate images
	docker-compose -f ./artifacts/docker-compose.yaml down
	dkcl
	dkrm

   #Cleanup the stores
	rm -rf ./fabric-client-kv-*
  
	generateCerts
  	replacePrivateKey
  	generateChannelArtifacts

  
	#Start the network
  
  # (cd ./fabric-ca/docker/server
  #   echo $PWD
  #   docker-compose up -d
  # )
	docker-compose -f ./artifacts/docker-compose.yaml up -d
	echo
}

function installNodeModules() {
	echo
	if [ -d node_modules ]; then
		echo "============== node modules installed already ============="
	else
		echo "============== Installing node modules ============="
		npm install
	fi
	echo
}

function generateCerts() {
echo "##### Generate certificates using cryptogen tool #########"

  if [ -d "./artifacts/channel/crypto-config" ]; then
    rm -Rf ./artifacts/channel/crypto-config
  fi
  (cd ./artifacts/channel
  export FABRIC_CFG_PATH=$PWD
  echo $PWD	
  which cryptogen
  if [ "$?" -ne 0 ]; then
    echo "cryptogen tool not found. exiting"
    exit 1
  fi
  
   set -x
  	./bin/cryptogen generate --config=./cryptogen.yaml
  	res=$?
   set +x
	if [ $res -ne 0 ]; then
	echo "Failed to generate certificates..."
	exit 1
	fi
  )
  echo
}
CHANNEL_NAME="mychannel"
# Generate orderer genesis block and channel configuration transaction with configtxgen
function generateChannelArtifacts() {
(cd ./artifacts/channel
  export FABRIC_CFG_PATH=$PWD	
  which configtxgen
  if [ "$?" -ne 0 ]; then
    echo "configtxgen tool not found. exiting"
    exit 1
  fi
   set -x
   echo $PWD
  rm -Rf ./genesis.block
  rm -Rf ./$CHANNEL_NAME.tx
  rm -Rf ./Org11MSPanchors.tx
  rm -Rf ./Org2MSPanchors.tx
  rm -Rf ./Org3MSPanchors.tx
  echo "#########  Generating Orderer Genesis block ##############"
  ./bin/configtxgen -profile TwoOrgsOrdererGenesis -outputBlock ./genesis.block
  res=$?
  if [ $res -ne 0 ]; then
    echo "Failed to generate orderer genesis block..."
    exit 1
  fi
  echo
  echo "### Generating channel configuration transaction 'channel.tx' ###"
  ./bin/configtxgen -profile TwoOrgsChannel -outputCreateChannelTx ./$CHANNEL_NAME.tx -channelID $CHANNEL_NAME
  res=$?
  if [ $res -ne 0 ]; then
    echo "Failed to generate channel configuration transaction..."
    exit 1
  fi

  echo
  echo "#################################################################"
  echo "#######    Generating anchor peer update for Org1MSP   ##########"
  echo "#################################################################"
  set -x
  ./bin/configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate ./Org1MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Org1MSP
  res=$?
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate anchor peer update for Org1MSP..."
    exit 1
  fi

  echo
  echo "#################################################################"
  echo "#######    Generating anchor peer update for Org2MSP   ##########"
  echo "#################################################################"
  set -x
  ./bin/configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate ./Org2MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Org2MSP
  res=$?
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate anchor peer update for Org2MSP..."
    exit 1
  fi
  echo
  echo "#################################################################"
  echo "#######    Generating anchor peer update for Org3MSP   ##########"
  echo "#################################################################"
  set -x
  ./bin/configtxgen -profile TwoOrgsChannel -outputAnchorPeersUpdate ./Org3MSPanchors.tx -channelID $CHANNEL_NAME -asOrg Org3MSP
  res=$?
  set +x
  if [ $res -ne 0 ]; then
    echo "Failed to generate anchor peer update for Org2MSP..."
    exit 1
  fi
  )
  echo
}
function replacePrivateKey() {
  # sed on MacOSX does not support -i flag with a null extension. We will use
  # 't' for our back-up's extension and delete it at the end of the function
  ARCH=$(uname -s | grep Darwin)
  if [ "$ARCH" == "Darwin" ]; then
    OPTS="-it"
  else
    OPTS="-i"
  fi
  if [ -d "./artifacts/network-config.yaml" ]; then
    rm -Rf ./artifacts/network-config.yaml
  fi
  # Copy the template to the file that will be modified to add the private key
  cp ./artifacts/network-config-template.yaml ./artifacts/network-config.yaml

  # The next steps will replace the template's contents with the
  # actual values of the private key file names for the two CAs.
  CURRENT_DIR=$PWD
  cd ./artifacts/channel/crypto-config/peerOrganizations/org1.example.com/users/Admin@org1.example.com/msp/keystore/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/ORG1_PRIVATE_KEY/${PRIV_KEY}/g" ./artifacts/network-config.yaml

  CURRENT_DIR=$PWD
  cd ./artifacts/channel/crypto-config/peerOrganizations/org2.example.com/users/Admin@org2.example.com/msp/keystore/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/ORG2_PRIVATE_KEY/${PRIV_KEY}/g" ./artifacts/network-config.yaml

  CURRENT_DIR=$PWD
  cd ./artifacts/channel/crypto-config/peerOrganizations/org3.example.com/users/Admin@org3.example.com/msp/keystore/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/ORG3_PRIVATE_KEY/${PRIV_KEY}/g" ./artifacts/network-config.yaml

  cp ./artifacts/docker-compose-template.yaml ./artifacts/docker-compose.yaml

  # The next steps will replace the template's contents with the
  # actual values of the private key file names for the two CAs.
  CURRENT_DIR=$PWD
  cd ./artifacts/channel/crypto-config/peerOrganizations/org1.example.com/ca/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/CA1_PRIVATE_KEY/${PRIV_KEY}/g" ./artifacts/docker-compose.yaml


  CURRENT_DIR=$PWD
  cd ./artifacts/channel/crypto-config/peerOrganizations/org2.example.com/ca/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/CA2_PRIVATE_KEY/${PRIV_KEY}/g" ./artifacts/docker-compose.yaml

  CURRENT_DIR=$PWD
  cd ./artifacts/channel/crypto-config/peerOrganizations/org3.example.com/ca/
  PRIV_KEY=$(ls *_sk)
  cd "$CURRENT_DIR"
  sed $OPTS "s/CA3_PRIVATE_KEY/${PRIV_KEY}/g" ./artifacts/docker-compose.yaml
  # If MacOSX, remove the temporary backup of the docker-compose file
  if [ "$ARCH" == "Darwin" ]; then
    rm docker-compose-e2e.yamlt
  fi
}

restartNetwork
installNodeModules

PORT=4000 node app
