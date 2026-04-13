#!/bin/sh

echo "SYN_AXON_AHA_PROVISION=`docker compose exec aha python -m synapse.tools.aha.provision.service 00.axon | awk -F' ' '{print $NF}'`" >> gen-env.txt
echo "SYN_JSONSTOR_AHA_PROVISION=`docker compose exec aha python -m synapse.tools.aha.provision.service 00.jsonstor | awk -F' ' '{print $NF}'`" >> gen-env.txt
echo "SYN_CORTEX_AHA_PROVISION=`docker compose exec aha python -m synapse.tools.aha.provision.service 00.cortex | awk -F' ' '{print $NF}'`" >> gen-env.txt
echo "SYN_OPTIC_AHA_PROVISION=`docker compose exec aha python -m synapse.tools.aha.provision.service 00.optic | awk -F' ' '{print $NF}'`" >> gen-env.txt