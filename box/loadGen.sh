while :
do
  curl -s http://staging.customera.127.0.0.1.nip.io > /dev/null
  curl -s http://customera.127.0.0.1.nip.io > /dev/null
  curl -s http://staging.customerb.127.0.0.1.nip.io > /dev/null
  curl -s http://customerb.127.0.0.1.nip.io > /dev/null
  curl -s http://staging.customerc.127.0.0.1.nip.io > /dev/null
  curl -s http://customerc.127.0.0.1.nip.io > /dev/null
  sleep 2
done
