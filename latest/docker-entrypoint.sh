#!/bin/bash
set -e

REPLICA_SET_HOST=${REPLICA_SET_HOST:=localhost}
REPLICA_SET_NAME=${REPLICA_SET_NAME:=rs0}
USERNAME=${USERNAME:=dev}
PASSWORD=${PASSWORD:=dev}

function waitForMongo {
    port=$1
    user=$2
    pass=$3
    n=0
    until [ $n -ge 20 ]
    do
        if [ -z "$user" ]; then
            mongo admin --quiet --port $port --eval "db" && break
        else
            echo "trying: $port $user $pass"
            mongo admin --quiet --port $port -u $user -p $pass --eval "db" && break
        fi
        n=$[$n+1]
        sleep 2
    done
}

if [ ! "$(ls -A /data/db1)" ]; then
    mkdir -p /data/db1
    mkdir -p /data/db2
    mkdir -p /data/db3

    mongod --dbpath /data/db1 &
    MONGO_PID=$!

    waitForMongo 27017

    echo "CREATING USER ACCOUNT"
    mongo admin --eval "db.createUser({ user: '$USERNAME', pwd: '$PASSWORD', roles: ['root', 'restore', 'readWriteAnyDatabase', 'dbAdminAnyDatabase'] })"

    echo "KILLING MONGO"
    kill $MONGO_PID
    wait $MONGO_PID
fi

echo "WRITING KEYFILE"

openssl rand -base64 741 > /var/mongo_keyfile
chown mongodb /var/mongo_keyfile
chmod 600 /var/mongo_keyfile

echo "STARTING CLUSTER"

mongod --replSet $REPLICA_SET_NAME --port 27019 --bind_ip_all --dbpath /data/db3 --auth  --keyFile /var/mongo_keyfile  --oplogSize 128 &
DB3_PID=$!
mongod --replSet $REPLICA_SET_NAME --port 27018 --bind_ip_all --dbpath /data/db2 --auth --keyFile /var/mongo_keyfile --oplogSize 128  &
DB2_PID=$!
mongod --replSet $REPLICA_SET_NAME --port 27017 --bind_ip_all --dbpath /data/db1 --auth --keyFile /var/mongo_keyfile --oplogSize 128  &
DB1_PID=$!

waitForMongo 27017 $USERNAME $PASSWORD
waitForMongo 27018
waitForMongo 27019

echo "CONFIGURING REPLICA SET: $REPLICA_SET_HOST"
CONFIG="{ _id: '$REPLICA_SET_NAME', members: [{_id: 0, host: '$REPLICA_SET_HOST:27017' }, { _id: 1, host: '$REPLICA_SET_HOST:27018' }, { _id: 2, host: '$REPLICA_SET_HOST:27019' } ]}"
mongo admin --port 27017 -u $USERNAME -p $PASSWORD --eval "rs.initiate($CONFIG)"

waitForMongo 27018 $USERNAME $PASSWORD
waitForMongo 27019 $USERNAME $PASSWORD

mongo admin --port 27017 -u $USERNAME -p $PASSWORD --eval "db.runCommand({ setParameter: 1, quiet: 1 })"
mongo admin --port 27018 -u $USERNAME -p $PASSWORD --eval "db.runCommand({ setParameter: 1, quiet: 1 })"
mongo admin --port 27019 -u $USERNAME -p $PASSWORD --eval "db.runCommand({ setParameter: 1, quiet: 1 })"

echo "REPLICA SET ONLINE"


trap 'echo "KILLING"; kill $DB1_PID $DB2_PID $DB3_PID; wait $DB1_PID; wait $DB2_PID; wait $DB3_PID' SIGINT SIGTERM EXIT

wait $DB1_PID
wait $DB2_PID
wait $DB3_PID
