@tool
## Shared constants, enums and defaults for the Godot Collab add-on.
##
## This class only holds immutable data. It must never reference editor
## internals so it stays loadable in headless tests.
class_name CollabConstants
extends RefCounted

## Wire protocol version. Bump whenever the packet format changes in a way
## that older peers cannot understand. Peers with a different version are
## rejected during the handshake instead of being allowed to desync.
## v2: scene operations are scene-id aware, and workspace (file/scene) requests
## and scene-focus broadcasts were added.
const PROTOCOL_VERSION: int = 3

## Magic marker placed at the front of every packet so garbage/foreign traffic
## is discarded before it reaches the decoder. Declared as a static var because
## [PackedByteArray] literals are not constant expressions.
static var PACKET_MAGIC: PackedByteArray = PackedByteArray([0x47, 0x43, 0x4C, 0x42]) # "GCLB"

## 4 (magic) + 1 (version) + 1 (type) + 4 (payload length)
const HEADER_SIZE: int = 10

## Hard upper bound for a single decoded packet payload. Anything larger is
## rejected. This keeps a malicious or buggy peer from allocating unbounded
## memory through var decoding. Sized to carry a single workspace file (see
## [constant MAX_WORKSPACE_FILE_BYTES]) plus protocol overhead.
const MAX_PACKET_PAYLOAD: int = 4 << 20 # 4 MiB

## Hard upper bound for a single file-transfer data chunk (project transfer).
const MAX_TRANSFER_CHUNK: int = 512 * 1024 # 512 KiB

## Default UDP port used when hosting.
const DEFAULT_PORT: int = 45899

## Default maximum number of simultaneous remote peers.
const DEFAULT_MAX_PEERS: int = 8

## Default rendezvous HTTP endpoint. Empty means "no rendezvous configured",
## in which case only direct (IP:port) connections are offered. Kept empty by
## default so a fresh install does not depend on any external service; users who
## want short, shareable invitation codes opt in by setting a URL in Editor
## Settings (`godot_collab/network/rendezvous_url`).
const DEFAULT_RENDEZVOUS_URL: String = ""

## Session invitation codes expire after this many seconds unless refreshed.
const INVITE_TTL_SECONDS: int = 600

## How often (seconds) the host refreshes its rendezvous registration.
const RENDEZVOUS_REFRESH_SECONDS: float = 120.0

## Cursor updates are unreliable and rate limited on the sending side.
const CURSOR_SEND_HZ: float = 25.0

## Remote cursors older than this are hidden (seconds).
const CURSOR_STALE_SECONDS: float = 3.0

## Remote cursors are interpolated toward the latest sample over this window.
const CURSOR_INTERP_SECONDS: float = 0.09

## Maximum size of a single inbound control message (ops, snapshot headers...).
const MAX_OPS_PER_MESSAGE: int = 256

## Hard upper bound for a single workspace file/scene payload (create scene or
## add file). Larger files must use the project transfer path.
const MAX_WORKSPACE_FILE_BYTES: int = 2 * 1024 * 1024 # 2 MiB

## Upper bound on the number of scenes advertised in a SCENE_LIST message.
const MAX_SCENE_LIST: int = 2048

## File extensions a peer may create or overwrite through the workspace service.
## Covers source text plus the common binary/text assets a user may drag into the
## project. Content is written verbatim and never executed; larger assets use the
## project transfer path instead.
const WRITABLE_EXTENSIONS: Array[String] = [
	# Scenes and resources.
	".tscn", ".scn", ".escn", ".tres", ".res", ".import",
	# Scripts and shaders.
	".gd", ".gdshader", ".shader", ".gdshaderinc",
	# Text/config.
	".json", ".txt", ".cfg", ".md", ".csv", ".xml", ".po", ".ini", ".toml",
	# Images.
	".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tga", ".svg", ".gif",
	".hdr", ".exr", ".dds", ".ktx",
	# 3D models.
	".obj", ".mtl", ".gltf", ".glb", ".fbx", ".dae", ".blend", ".escn",
	# Audio.
	".wav", ".ogg", ".mp3", ".oggstr",
	# Fonts.
	".ttf", ".otf", ".woff", ".woff2", ".fnt",
	# Video.
	".ogv",
]

## Node classes that may be used as the root of a newly created scene.
const SCENE_ROOT_CLASSES: Array[String] = [
	"Node", "Node2D", "Node3D", "Control", "CanvasLayer",
]

## Workspace request kinds understood by the host.
enum WorkspaceOp {
	CREATE_SCENE = 0, ## Create a new (empty) scene file.
	ADD_FILE = 1, ## Create or overwrite a text file inside the project.
	LIST_SCENES = 2, ## Ask the host to re-advertise the project's scenes.
	DELETE_FILE = 3, ## Remove a project file (the second half of a rename).
}

## Supported collaboration modes for a session.
enum WorkspaceMode {
	HOST_WORKSPACE = 0, ## Host owns the authoritative scene + project snapshot.
	GIT_PRESENCE = 1, ## Presence/cursors only; git distributes files.
}

## Connection lifecycle as seen by the dock.
enum ConnectionState {
	DISCONNECTED = 0,
	HOSTING = 1,
	CONNECTING = 2,
	CONNECTED = 3,
	DISCONNECTING = 4,
}

## How reachable a hosted session appears to be.
enum ConnectivityState {
	UNKNOWN = 0, ## Not verified yet.
	LAN_ONLY = 1, ## Reachable only inside the local network.
	DIRECT = 2, ## Externally reachable (UPnP mapped / manual forward).
	RELAY = 3, ## Reserved for a future relay path.
}
