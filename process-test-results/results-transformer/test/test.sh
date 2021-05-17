#!/bin/bash
pass=0
for dir in */; do
  echo Running test: $dir
  diff ${dir}expected_output.xml <(xsltproc ../transform.xml ${dir}input.xml | tidy -xml -i -q -w 1000 -)
  result=$?
  if [ ${result} == 0 ]; then 
    echo PASS $dir
  else
    echo FAIL $dir
  fi
  [ $pass == "0" ] && [ $result == "0" ] && pass=0 || pass=1
done
exit ${pass}
