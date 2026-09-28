# DOOM's program (apple/rvvm/build_app.sh): doomgeneric (the sibling checkout
# ../doomgeneric) on picolibc, its platform in doom_rv.c; its music mus_rv.c,
# sampled instruments from DOOMMUS.INS (docs/RVV2_DOOM.md, MU3).
dg="$root/../doomgeneric/doomgeneric"
[ -d "$dg" ] || { echo "no doomgeneric at $dg" >&2; exit 1; }
compat="$root/apple/rvvm/doom/compat"
PICOLIBC=1
python3 "$root/tools/adb_ascii_h.py" > "$out/adb_ascii.h"   # the ADB micro's own keymap
HEAP=0xB00000                           # the 6 MB zone, the WAD's cached lumps, the screen
STACK=0x40000
# SDL's stand-in (compat/SDL.h) in every file.
EXTRA_CFLAGS="-I$out -I$compat -include $compat/SDL.h -DFEATURE_SOUND -DCMAP256 -DDOOMGENERIC_RESX=320 -DDOOMGENERIC_RESY=200 -DNORMALUNIX -D_DEFAULT_SOURCE -I$dg -Wno-everything"
case "${DOOM_PROFILE:-}" in             # sim/profile_doom.sh's builds
    warp)     EXTRA_CFLAGS="$EXTRA_CFLAGS -DDOOM_WARP";;       # straight into E1M1
    timedemo) EXTRA_CFLAGS="$EXTRA_CFLAGS -DDOOM_TIMEDEMO";;   # DEMO1, no cap
esac
EXTRA_SRCS=""                           # (this folder's *.c are built too: doom_rv.c, snd_rv.c, mus_rv.c)
for f in dummy am_map doomdef doomstat dstrings d_event d_items d_iwad d_loop d_main d_mode d_net f_finale \
         f_wipe g_game hu_lib hu_stuff info i_cdmus i_endoom i_joystick i_scale i_sound i_system i_timer memio \
         m_argv m_bbox m_cheat m_config m_controls m_fixed m_menu m_misc m_random mus2mid p_ceilng p_doors p_enemy \
         p_floor p_inter p_lights p_map p_maputl p_mobj p_plats p_pspr p_saveg p_setup p_sight p_spec p_switch \
         p_telept p_tick p_user r_bsp r_data r_draw r_main r_plane r_segs r_sky r_things sha1 sounds statdump \
         st_lib st_stuff s_sound tables v_video wi_stuff w_checksum w_file w_main w_wad z_zone w_file_stdc \
         i_input i_video doomgeneric; do
    EXTRA_SRCS="$EXTRA_SRCS $dg/$f.c"
done
