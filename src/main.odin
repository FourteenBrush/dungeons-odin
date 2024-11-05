package dungeons

// on fedora, needs:
// SDL2-devel
// SDL2_image-devel
// SDL2_ttf-devel
import "core:os"
import "core:fmt"
import "core:log"

import sdl "vendor:sdl2"
import img "vendor:sdl2/image"
import "vendor:sdl2/ttf"

WINDOW_TITLE :: "yesn't"
WINDOW_WIDTH :: 900
WINDOW_HEIGHT :: 600
WINDOW_MIN_WIDTH :: 300
WINDOW_MIN_HEIGTH :: 200

BACKGROUND_COLOR :: sdl.Color {173, 34, 76, 0}
FONT_SIZE :: 30

TARGET_MSPF :: 1000 / 60 // 60 fps
ANIMATION_FPS :: 9

Vec2 :: [2]i32

main :: proc() {
    log_level := log.Level.Debug when ODIN_DEBUG else log.Level.Warning
    context.logger = log.create_console_logger(log_level, { .Level, .Terminal_Color })
    defer log.destroy_console_logger(context.logger)

    // override level headers to not include "---"
    for &header in log.Level_Headers {
        header = header[:len(header) - len("--- ")]
    }

    sdl.SetHint(sdl.HINT_VIDEO_X11_NET_WM_BYPASS_COMPOSITOR, "0")

    if sdl.Init({.VIDEO}) != 0 do fail("Failed to initialize SDL:", sdl.GetError())
    defer sdl.Quit()

    img_flags :: img.InitFlags {.PNG}
    if img.Init(img_flags) & img_flags != img_flags {
        fail("Failed to initialize SDL_Image:", img.GetError())
    }
    defer img.Quit()

    if ttf.Init() != 0 do fail("Failed to initialize SDL_ttf", ttf.GetError())
    defer ttf.Quit()

    state, err := initialize_state()
    if err != nil do fail(err)

    window := sdl.CreateWindow(WINDOW_TITLE, sdl.WINDOWPOS_CENTERED, sdl.WINDOWPOS_CENTERED, WINDOW_WIDTH, WINDOW_HEIGHT, {.RESIZABLE})
    if window == nil do fail("Failed creating window:", sdl.GetError())
    defer sdl.DestroyWindow(window)

    renderer := sdl.CreateRenderer(window, 0, {.PRESENTVSYNC})
    if renderer == nil do fail("Failed to create renderer:", sdl.GetError())
    defer sdl.DestroyRenderer(renderer)

    err = state_post_window_creation(&state, window, renderer)
    if err != nil do fail(err)
    defer destroy_state(&state)

    begin_game_loop(&state)
}

// Returns an err to or_return on when the passed return value indicates an error condition
@(require_results)
invoke :: proc { invoke_int, invoke_ptr }

@(require_results)
invoke_ptr :: #force_inline proc(ret: $P/^$T) -> (ptr: P, err: cstring) {
    return ret, (sdl.GetError() if ret == nil else nil)
}

@(require_results)
invoke_int :: #force_inline proc(ret: i32) -> (err: cstring) {
    return sdl.GetError() if ret != 0 else nil
}

// TODO: what even is this crap
@(deferred_none=exit)
fail :: proc(args: ..any) {
    log.fatal(..args)
}

exit :: proc() {
    os.exit(1)
}

/*
                // FPS over last 30 frames.
                @static frame_times: [30]f32
                @static frame_times_idx: int

                frame_times[frame_times_idx % len(frame_times)] = dt
                frame_times_idx += 1

                frame_time: f32
                for time in frame_times {
                    frame_time += time
                }

                buf: [24]byte
                fps := strconv.itoa(buf[:], int(math.round(len(frame_times)/frame_time)))
*/

State :: struct {
    window: ^sdl.Window,
    renderer: ^sdl.Renderer,
    surfaces_temp: [Asset]^sdl.Surface,
    textures: [Asset]^sdl.Texture,
    background_render_target: ^sdl.Texture,

    animations: [AnimationState]Animation,
    curr_animation: AnimationState,

    frame_times: [30]u32,
    frames_count: u32,
    prev_frame_time: u32,

    font: ^ttf.Font,

    player_pos: Vec2,
    player_vel: Vec2,
}

Asset :: enum {
    BgLayer1,
    BgLayer2,
    BgLayer3,
    PlayerIdle,
    PlayerRunning,
    PlayerJumping,
}

@(rodata)
asset_paths := [Asset]cstring {
    .BgLayer1          = "assets/background_layer_1.png",
    .BgLayer2          = "assets/background_layer_2.png",
    .BgLayer3          = "assets/background_layer_3.png",
    .PlayerIdle        = "assets/idle.png",
    .PlayerRunning     = "assets/run.png",
    .PlayerJumping     = "assets/jump.png",
}

initialize_state :: proc() -> (state: State, err: cstring) {
    for asset in Asset {
        surface := img.Load(asset_paths[asset])
        if surface == nil {
            for asset in min(Asset)..<asset do sdl.FreeSurface(state.surfaces_temp[asset])
            return state, img.GetError()
        }

        state.surfaces_temp[asset] = surface
    }

    state.font = invoke(ttf.OpenFont("assets/FreeSansBold.ttf", FONT_SIZE)) or_return
    return state, nil
}

state_post_window_creation :: proc(state: ^State, window: ^sdl.Window, renderer: ^sdl.Renderer) -> (err: cstring) {
    state.window = window
    state.renderer = renderer
    
    sdl.SetWindowMinimumSize(state.window, WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGTH)

    for asset in Asset {
        surface := state.surfaces_temp[asset]
        texture := sdl.CreateTextureFromSurface(state.renderer, surface)
        if texture == nil {
            for asset in min(Asset)..<asset do sdl.DestroyTexture(state.textures[asset])
            sdl.GetErrorString()
            return sdl.GetError()
        }

        sdl.FreeSurface(surface)
        state.surfaces_temp[asset] = nil
        state.textures[asset] = texture
    }

    state.background_render_target = invoke(sdl.CreateTexture(state.renderer, .RGBA32, .TARGET, window_dims(state))) or_return

    for anim_state in AnimationState {
        descriptor := animation_descriptors[anim_state]
        texture := state.textures[descriptor.asset]
        texture_x, _ := texture_dims(texture)

        assert(descriptor.nframes * descriptor.frame_dims.x + descriptor.lpad <= u16(texture_x), "frames cant fit in animation width")
        state.animations[anim_state] = Animation { texture=texture, descriptor=descriptor }
    }

    return nil
}

destroy_state :: proc(state: ^State) {
    sdl.DestroyTexture(state.background_render_target)
    ttf.CloseFont(state.font)
}

begin_game_loop :: proc(state: ^State) {
    for {
        start_ms := sdl.GetTicks()

        update(state) or_break
        render(state)

        frame_time := sdl.GetTicks() - start_ms
        state.prev_frame_time = frame_time
        state.frames_count += 1
        state.frame_times[state.frames_count % len(state.frame_times)] = frame_time

        if frame_time < TARGET_MSPF {
            sdl.Delay(TARGET_MSPF - frame_time)
        }

        free_all(context.temp_allocator)
    }
}

update :: proc(state: ^State) -> (keep_running: bool) {
    event: sdl.Event
    for sdl.PollEvent(&event) {
        handle_event(state, event) or_return
    }

    keyboard_state := sdl.GetKeyboardState(nil)
    is_pressed :: proc(keyboard_state: [^]u8, key: sdl.Scancode) -> bool {
        return keyboard_state[key] == 1
    }
    switch {
    case is_pressed(keyboard_state, .RIGHT), is_pressed(keyboard_state, .Z):
        state.curr_animation = .RunningForwards
    case is_pressed(keyboard_state, .LEFT), is_pressed(keyboard_state, .Q):
        state.curr_animation = .RunningBackwards
    case is_pressed(keyboard_state, .SPACE):
        state.curr_animation = .Jumping
    }

    if state.frames_count % ANIMATION_FPS == 0 {
        update_animation(&state.animations[state.curr_animation])
    }

    state.player_pos += state.player_vel
    sdl.SetWindowTitle(state.window, fmt.ctprintf("[x:%d, y:%d]", expand_values(state.player_pos)))
    return true
}

handle_event :: proc(state: ^State, event: sdl.Event) -> (keep_running: bool) {
    #partial switch event.type {
    case .QUIT: return false
    case .WINDOWEVENT: if event.window.event == .CLOSE do return false
    case .KEYDOWN:
        #partial switch event.key.keysym.sym {
        case .LEFT: state.player_vel.x -= 2
        case .RIGHT: state.player_vel.x += 2
        case .DOWN: state.player_vel.y -= 2
        case .UP: state.player_vel.y += 2
        }
    }
    return true
}

render :: proc(state: ^State) {
    defer sdl.RenderPresent(state.renderer)
    sdl.SetRenderDrawColor(state.renderer, 145, 118, 98, 100)
    sdl.RenderClear(state.renderer)

    if err := draw_background(state); err != nil {
        fmt.eprintln("Error", err)
    }

    if sdl.SetRenderDrawColor(state.renderer, expand_values(BACKGROUND_COLOR)) != 0 {
        fmt.eprintln(sdl.GetError())
    }

    draw_animation(state)

    draw_fps: /*if state.prev_frame_time != 0*/ {
        text := fmt.ctprint("mspf:", state.prev_frame_time)
        //text := fmt.ctprint("fps:", 1000 / state.prev_frame_time)
        surface := ttf.RenderText_Blended(state.font, text, { 33, 10, 27, 0 })
        if surface == nil {
            fmt.eprintln(ttf.GetError())
            break draw_fps
        }

        texture := sdl.CreateTextureFromSurface(state.renderer, surface)
        if texture == nil {
            fmt.eprintln(sdl.GetError())
            break draw_fps
        }

        sdl.FreeSurface(surface)

        src := sdl.Rect { w=surface.w, h=surface.h }
        dest := sdl.Rect { x=20, y=20, h=50 }

        max_width :: 300
        if ttf.MeasureText(state.font, text, max_width, &dest.w, nil) != 0 {
            fmt.eprintln(ttf.GetError())
            break draw_fps
        }

        if sdl.RenderCopy(state.renderer, texture, &src, &dest) != 0 {
            fmt.eprintln(sdl.GetError())
        }
    }
}

// TODO: fix scaling

draw_background :: proc(state: ^State) -> (err: cstring) {
    invoke(sdl.SetRenderTarget(state.renderer, state.background_render_target)) or_return

    for asset in Asset.BgLayer1..<Asset.BgLayer3 {
        texture := state.textures[asset]
        invoke(sdl.RenderCopy(state.renderer, texture, nil, nil)) or_return
    }

    invoke(sdl.SetRenderTarget(state.renderer, nil)) or_return

    window_w, window_h := window_dims(state)
    x0 := -state.player_pos.x % window_w
    dst := sdl.Rect { x=x0, w=window_w, h=window_h }

    invoke(sdl.RenderCopy(state.renderer, state.background_render_target, nil, &dst)) or_return

    sign := 1 if state.player_pos.x >= 0 else -1
    dst.x = x0 + window_w * i32(sign)
    // only render a second time if it would actually be shown on screen
    if state.player_pos.x % window_w != 0 {
        invoke(sdl.RenderCopy(state.renderer, state.background_render_target, nil, &dst)) or_return
    }
    return nil
}

texture_dims :: proc(texture: ^sdl.Texture) -> (w, h: i32) {
    // assuming textures are only obtained from sdl, no need for an error param
    assert(texture != nil)
    sdl.QueryTexture(texture, nil, nil, &w, &h)
    return
}

window_dims :: proc(state: ^State) -> (w, h: i32) {
    sdl.GetWindowSize(state.window, &w, &h)
    return
}
