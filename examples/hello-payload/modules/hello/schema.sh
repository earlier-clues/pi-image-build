# hello module — writes a sentinel file inside the chroot. Both vars
# are optional with sensible defaults so the bare `core + hello` payload
# works out of the box.

optional HELLO_MESSAGE default="hello from pi-image-build"
optional HELLO_OUTPUT_PATH default=/etc/pibuild-hello
