package dungeons

import "core:fmt"

import sdl "vendor:sdl2"

PLAYER_SCALE_FACTOR :: 3

AnimationState :: enum {
    Idle,
    RunningForwards,
    RunningBackwards,
    Jumping,
}

Animation :: struct {
    texture: ^sdl.Texture,
    using descriptor: AnimationDescriptor,
    current_frame: u16,
}

// Animation descriptors, required by the application, defines the layout of a certain animation.
AnimationDescriptor :: struct {
    asset: Asset,
    nframes: u16,
    frame_dims: [2]u16,
    lpad: u16,
}

@(rodata)
animation_descriptors := [AnimationState]AnimationDescriptor {
    .Idle             = { asset = .PlayerIdle,    nframes = 4, frame_dims = { 24 + 43, 86 } },
    .RunningForwards  = { asset = .PlayerRunning, nframes = 7, frame_dims = { 480 / 7, 86 }, lpad = 15 },
    .RunningBackwards = { asset = .PlayerRunning, nframes = 7, frame_dims = { 480 / 7, 86 }, lpad = 15 },
    .Jumping          = { asset = .PlayerRunning, nframes = 6, frame_dims = { 480 / 5, 86 } },
}

update_animation :: proc(anim: ^Animation) {
    anim.current_frame = (anim.current_frame + 1) % anim.nframes
}

draw_animation :: proc(state: ^State) {
    animation := state.animations[state.curr_animation]
    src_x := animation.frame_dims.x * animation.current_frame + animation.lpad
    player_w, player_h := i32(animation.frame_dims.x) * PLAYER_SCALE_FACTOR, i32(animation.frame_dims.y) * PLAYER_SCALE_FACTOR
    src := sdl.Rect { x=i32(src_x), w=i32(animation.frame_dims.x), h=i32(animation.frame_dims.y) }

    window_w, window_h := window_dims(state)
    dst := sdl.Rect {
        x=(window_w / 2 - player_w / 2),
        y=(window_h / 2 - player_h / 2),
        w=player_w, h=player_h,
    }

    if sdl.RenderCopy(state.renderer, animation.texture, &src, &dst) != 0 {
        fmt.eprintln(sdl.GetError())
    }

    sdl.SetRenderDrawColor(state.renderer, 206, 40, 18, 0)
    sdl.RenderDrawLine(state.renderer, window_w / 2, window_h - 80, window_w / 2, window_h - 50)
}
