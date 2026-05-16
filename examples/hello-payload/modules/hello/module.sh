# hello module — writes the canonical pi-image-build sentinel file.
# Inputs: HELLO_MESSAGE, HELLO_OUTPUT_PATH (both optional, defaulted by
# schema.sh).

install -d -m 755 "$(dirname "$HELLO_OUTPUT_PATH")"
{
    echo "pi-image-build hello-payload OK at $(date -u +%FT%TZ)"
    echo "message: $HELLO_MESSAGE"
} > "$HELLO_OUTPUT_PATH"
chmod 644 "$HELLO_OUTPUT_PATH"
