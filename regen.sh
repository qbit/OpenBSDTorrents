#!/bin/sh
#$RedRiver: regen.sh,v 1.10 2010/03/08 20:19:37 andrew Exp $

. /etc/OpenBSDTorrents.conf

cd ${OBT_DIR_HOME}
PIDFILE=${OBT_DIR_HOME}/run/regen.pid

if [ -e ${PIDFILE} ]; then
        PID=`head -1 ${PIDFILE}`
        kill -0 ${PID} 2> /dev/null
        if [ $? -eq 0 ]; then
                echo $0 Already running
                exit 1
        fi
fi
echo $$ > ${PIDFILE}

if [[ $1 != skip ]]; then
	echo 
	echo ${OBT_DIR_HOME}/MakeTorrents.pl $*
	${OBT_DIR_HOME}/MakeTorrents.pl $*
fi

echo 
echo ${OBT_DIR_HOME}/CurrentTorrents.pl
${OBT_DIR_HOME}/CurrentTorrents.pl

echo 
echo ${OBT_DIR_HOME}/SeedTorrents[.pl
${OBT_DIR_HOME}/SeedTorrents.pl
