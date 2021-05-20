# test.sh #

Runs the transform.xml (xslt) file over each input.xml, and tidy (```tidy -xml -i -q -w 1000``) before diffing against expected output for each subdirectory.

Fails if any outputs do not match the expected_output.xml files in there corresponding directories.