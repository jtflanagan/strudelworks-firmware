# DOOM's program (apple/rvvm/build_app.sh): doomgeneric (the sibling checkout
# ../doomgeneric) on picolibc, its platform in doom_rv.c; its music Chocolate
# Doom's OPL player and DBOPL (the sibling checkout ../chocolate-doom at the tag
# chocolate-doom-2.2.1, the last with DBOPL - docs/RVV2_DOOM.md, MU1).
dg="$root/../doomgeneric/doomgeneric"
[ -d "$dg" ] || { echo "no doomgeneric at $dg" >&2; exit 1; }
choc="$root/../chocolate-doom"
[ -f "$choc/opl/dbopl.c" ] || { echo "no chocolate-doom-2.2.1 at $choc (git -C $choc checkout chocolate-doom-2.2.1)" >&2; exit 1; }
compat="$root/apple/rvvm/doom/compat"
PICOLIBC=1
python3 "$root/tools/adb_ascii_h.py" > "$out/adb_ascii.h"   # the ADB micro's own keymap
HEAP=0xB00000                           # the 6 MB zone, the WAD's cached lumps, the screen
STACK=0x40000
# doomgeneric's headers before Chocolate Doom's (only midifile.h is wanted from
# its src/); SDL's stand-in (compat/SDL.h) in every file; Chocolate Doom's OPL
# player as doomgeneric's music module, our driver as OPL's only one.
EXTRA_CFLAGS="-I$out -I$compat -include $compat/SDL.h -DFEATURE_SOUND -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -DNORMALUNIX -D_DEFAULT_SOURCE -I$dg -I$choc/opl -I$choc/src -Dmusic_opl_module=DG_music_module -Dopl_sdl_driver=opl_rv_driver -Wno-everything"
EXTRA_SRCS="$choc/src/i_oplmusic.c $choc/src/midifile.c $choc/opl/opl.c $choc/opl/opl_queue.c $choc/opl/dbopl.c"
for f in dummy am_map doomdef doomstat dstrings d_event d_items d_iwad d_loop d_main d_mode d_net f_finale \
         f_wipe g_game hu_lib hu_stuff info i_cdmus i_endoom i_joystick i_scale i_sound i_system i_timer memio \
         m_argv m_bbox m_cheat m_config m_controls m_fixed m_menu m_misc m_random mus2mid p_ceilng p_doors p_enemy \
         p_floor p_inter p_lights p_map p_maputl p_mobj p_plats p_pspr p_saveg p_setup p_sight p_spec p_switch \
         p_telept p_tick p_user r_bsp r_data r_draw r_main r_plane r_segs r_sky r_things sha1 sounds statdump \
         st_lib st_stuff s_sound tables v_video wi_stuff w_checksum w_file w_main w_wad z_zone w_file_stdc \
         i_input i_video doomgeneric; do
    EXTRA_SRCS="$EXTRA_SRCS $dg/$f.c"
done
