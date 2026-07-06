# Adapter hook for non-native (e.g. protobuf message) values.
#
# ProtocGen.jl (or a package extension) implements these for its generated
# message types; the core only knows maps, lists, and the built-in scalars.

"CEL runtime type for a foreign value. Extended by proto adapters."
adapter_typeof(x) = CelError(:invalid_argument, "unsupported value type $(typeof(x))")

"""
Construct a message. `names` are candidate qualified type names (most
specific container prefix first), `fieldnames`/`vals` the initializers.
Extended by proto adapters.
"""
adapter_new_message(names, fieldnames, vals) =
    CelError(:unknown_type, "unknown message type: '$(first(names))'")
