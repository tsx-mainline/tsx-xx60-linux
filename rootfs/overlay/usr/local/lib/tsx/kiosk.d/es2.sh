# es2.sh: the kiosk hook of the xx60 for the Mali-450 GPU (lima).
#
# kiosk-session sources this file after its renderer choice. It runs as the
# kiosk user, in the session and in the browser role. The contract is in
# docs/kiosk-hooks.md of tsx-linux-common. This file reads KIOSK_GPU, render
# and renderdrv. It changes only KIOSK_GL_COMPOSITOR, KIOSK_GL_BROWSER,
# KIOSK_BROWSER_GL_FLAGS and KIOSK_DISABLE_FEATURES.
#
# The Mali-450 supports OpenGL ES 2.0 only. Chromium 152 asks for an ES 3.0
# context, and it has no ES2 fallback ("ES version fallback is disabled", also
# through ANGLE). The patched Chromium of the xx60 (tsx-xx60-chromium, check
# with "tsx-chromium-es2 check") has the fallback. ANGLE on GLES can then
# create the ES 2.0 context that lima offers.
#
# Test hook: TSX_ES2_TOOL names the tool that replaces tsx-chromium-es2.
case "${KIOSK_GPU:-auto}" in
browser)
	# GLES in the compositor. GPU compositing in the browser needs the patch
	# and a render node. WebGL2 needs ES 3.0, so it is off.
	KIOSK_GL_COMPOSITOR=1
	if [ -n "$render" ] && "${TSX_ES2_TOOL:-/usr/local/sbin/tsx-chromium-es2}" check >/dev/null 2>&1; then
		KIOSK_GL_BROWSER=1
		KIOSK_BROWSER_GL_FLAGS="--use-gl=angle --use-angle=gles --disable-webgl2"
		# ANGLE "passthrough shaders" (Chromium feature
		# AllowANGLEPassthroughShaders) give the driver the GLSL of Skia
		# untranslated. ANGLE then counts every sampler as used by the vertex
		# stage too, and the Mali-450 has 0 vertex texture units. Every textured
		# program fails to link ("VERTEX shader texture image units count
		# exceeds MAX_VERTEX_TEXTURE_IMAGE_UNITS(0)"). The page is then
		# transparent, which is black on the panel (2026-09-26). Translated
		# shaders work.
		case ",${KIOSK_DISABLE_FEATURES:-}," in
		*,AllowANGLEPassthroughShaders,*) ;;
		*) KIOSK_DISABLE_FEATURES="AllowANGLEPassthroughShaders${KIOSK_DISABLE_FEATURES:+,$KIOSK_DISABLE_FEATURES}";;
		esac
		log "es2 hook: KIOSK_GPU=browser, the Chromium ES2 patch is present: the browser uses the GPU through ANGLE on GLES 2.0"
	else
		KIOSK_GL_BROWSER=0
		log "KIOSK_GPU=browser but the Chromium ES2 patch is not present (tsx-chromium-es2 check): browser renders in software"
	fi;;
on|compositor|off)
	# The other modes stay as the script chose them. KIOSK_GPU=on still forces
	# the attempt with stock Chromium.
	;;
*)
	# auto (or a value that no hook knows). Stock Chromium cannot use a GPU
	# with GLES 2.0 only: its GPU process dies three times, and Chromium ends
	# up in software compositing anyway (measured on the TSW-1060,
	# 2026-09-26). So keep GLES in the compositor only.
	if [ "$KIOSK_GL_BROWSER" = 1 ] && [ -n "$render" ]; then
		for _d in ${TSX_RENDER_ES2_DRM:-lima}; do
			case "$renderdrv" in
			$_d)
				KIOSK_GL_BROWSER=0
				log "GPU is $renderdrv (GLES 2.0): stock Chromium needs GLES 3.0, browser renders in software (KIOSK_GPU=browser uses the ES2 patch)"
				break;;
			esac
		done
	fi;;
esac
