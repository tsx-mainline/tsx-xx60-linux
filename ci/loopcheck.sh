# Sourced by the tests that attach loop devices in a privileged container.
# Loop devices belong to the host kernel. If a container stops before it runs
# "losetup -d", its loop devices stay attached on the host after the image file
# is gone, and the desktop shows their partitions as volumes.
#   loop_mark FILE   run before the container: saves the list of loop devices
#   loop_new FILE    run after the container: prints the devices it left attached
# Never use "losetup -D" in a test: it detaches every loop device on the host.
loop_list() { losetup -a 2>/dev/null | sort; }
loop_mark() { loop_list > "$1"; }
loop_new() { loop_list | comm -13 "$1" -; }
