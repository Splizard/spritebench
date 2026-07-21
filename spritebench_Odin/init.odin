package main

import "shared:Toxin"
import Classes "shared:Godot_Odin_Binds/GD_Classes"
import GDW "shared:GDWrapper"
import "shared:GDWrapper/gdAPI"
import "core:fmt"
import "core:os"
import "base:runtime"
import "core:math"
import "core:slice"
import "core:strconv"

init:: proc ()  {
    Toxin.scene_inits[0] = &THIS_CLASS_NAME_deets


    Toxin.myMainLoopCallbacks.startup_func = MainLoopStartupCallback
    Toxin.myMainLoopCallbacks.frame_func = MainLoopFrameCallback
    gdAPI.RegisterMainLoopCallbacks(GDW.Library, &Toxin.myMainLoopCallbacks)

    //Register custom class.
    THIS_CLASS_NAME_deets.registerer->self_register(.INITIALIZATION_SCENE)
}

@(init)
asdf :: proc "contextless" () {
    Toxin.inits.scene = init
    Toxin.scene_inits[0] = &THIS_CLASS_NAME_deets
}

scene_tree_obj: ^GDW.Object
root_node_instance: ^GDW.Object

//Using these class methods.
texture: Classes.Texture2D
Texture_Class: Classes.Sprite2D_MethodBind_List
Node2D_Class: Classes.Node2D_MethodBind_List
Node_Class: Classes.Node_MethodBind_List

// Sprites-at-target benchmark: find the largest sprite count this language
// sustains at the target frame rate. This implementation only runs on desktop
// (headless, where the refresh rate is unknown), so the target is a fixed
// 60 fps. A window sustains the target only if its 1% low (99th-percentile
// frame time) holds 0.95×target, so frames that miss the budget fail the
// window even when the median pace is fine. Doubling/halving brackets the
// count, binary search refines it, and a best-of-3 verify re-measures at the
// answer, walking the count down until the median window passes.
// The result is one line: "<max_sprites> <target_fps> <fps_at_max>".
global_warmup::100
window_warmup::40
window_measure::120
start_count::20000
min_count::1250
max_count::2560000
sustain::0.95
refine_rounds::6
low_index::window_measure * 99 / 100
verify_windows::3
verify_step::16

target: f64 = 60
times: [window_measure]f64
sprites: [dynamic]^GDW.Object
lo: int = 0
hi: int = 0
rounds: int = 0
verifying: bool = false
verify_fps: [verify_windows]f64
verify_done: int = 0
trace: bool = false
done: bool = false
global_frame: int = 0
window_frame: int = 0

set_count :: proc(n: int) {
    for len(sprites) > n {
        s := pop(&sprites)
        Node_Class.queue_free->m_call(s)
    }
    for len(sprites) < n {
        inst := gdAPI.ClassDB.ConstructObject(&THIS_CLASS_NAME_deets.SN)
        GDW.addChild(root, &inst)
        append(&sprites, inst)
    }
    window_frame = 0
}

report :: proc(count: int, fps: f64) {
    done = true
    line := fmt.aprintf("%d %d %.2f\n", count, int(math.round(target)), fps)
    output_path := os.get_env_alloc("SPRITEBENCH_OUTPUT", context.allocator)
    if output_path != "" {
        _ = os.write_entire_file(output_path, transmute([]u8)line)
    } else {
        fmt.println(line)
    }
}

MainLoopFrameCallback :: proc "c" () {
    context = runtime.default_context()
    if done {
        return
    }
    delta:Toxin.float=0
    Node_Class.get_process_delta_time->m_call(root, r_ret = &delta)
    global_frame+=1
    if global_frame <= global_warmup {
        return
    }
    window_frame+=1
    if window_frame <= window_warmup {
        return
    }
    i := window_frame - window_warmup - 1
    times[i] = f64(delta)
    if i < window_measure - 1 {
        return
    }

    sorted := times
    slice.sort(sorted[:])
    fps := 1.0 / sorted[low_index]
    sustained := fps >= sustain * target
    count := len(sprites)
    if trace {
        fmt.eprintfln("TRACE count=%d fps=%.2f sustained=%v verifying=%v", count, fps, sustained, verifying)
    }

    if verifying {
        verify_fps[verify_done] = fps
        verify_done += 1
        if verify_done < verify_windows {
            set_count(count)
            return
        }
        slice.sort(verify_fps[:])
        median := verify_fps[verify_windows / 2]
        verify_done = 0
        if median >= sustain * target {
            report(count, median)
        } else if count <= min_count {
            report(0, median)
        } else {
            set_count(max(count - count / verify_step, min_count))
        }
        return
    }
    if sustained {
        lo = count
    } else {
        hi = count
    }
    if !sustained && count <= min_count {
        report(0, fps)
        return
    }
    if sustained && count >= max_count {
        verifying = true
        set_count(count)
        return
    }
    if hi == 0 {
        set_count(count * 2)
    } else if lo == 0 {
        set_count(max(count / 2, min_count))
    } else {
        rounds += 1
        if rounds > refine_rounds {
            verifying = true
            set_count(lo)
            return
        }
        set_count((lo + hi) / 2)
    }
}
root:^Toxin.Object
MainLoopStartupCallback :: proc "c" () {
    context = runtime.default_context()

    Classes.Sprite2D_Init_(&Texture_Class)
    Classes.Node2D_Init_(&Node2D_Class)
    Classes.Node_Init_(&Node_Class)

    //Setup an object to hold the MainLoop object.
    scene_tree_obj = GDW.getMainLoop()

    //Fetch the root of the current sceneTree
    root= GDW.getRoot()
    scene:= GDW.get_current_scene()
    Classes.Window_Init_(&Window_MethodBind_List)

    //Create a class. Your extension registerations should all be done and all classes available at this point.

    //A scene is not added when running editor mode unless there is already a default scene. Check for the scene before trying to add the child to it.
    if scene != nil {
        //You can add a node directly to the root.
        //Add the class to the root of the sceneTree
        trace = os.get_env_alloc("SPRITEBENCH_TRACE", context.allocator) != ""
        // Optional search seed (runner knob, not part of the metric): skips
        // the low ramp when a prior run already bracketed the answer.
        n := start_count
        if s := os.get_env_alloc("SPRITEBENCH_START", context.allocator); s != "" {
            if v, ok := strconv.parse_int(s); ok {
                n = clamp(v, min_count, max_count)
            }
        }
        set_count(n)
    } else {
        done = true
    };
};;
