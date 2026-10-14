# Minimal test project

A tiny 3D scene (`main.tscn`: ground, cube, sun, camera) used for the two-editor
integration tests in `docs/TESTING.md`.

## Setup

1. Copy the add-on into this project:

   ```sh
   mkdir -p addons
   cp -r ../../addons/godot_collab addons/godot_collab
   ```

2. Open this folder (`tests/minimal_project`) as a project in Godot 4.7.2.
3. `Project > Project Settings > Plugins > Godot Collab > Enable`.
4. Make a **second copy of this whole folder** and open it in a second editor
   instance to test host/client behaviour.
