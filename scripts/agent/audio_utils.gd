class_name AudioUtils
extends RefCounted

## Utilidades de audio puras (sin estado, testeables) para el agente Gemini Live.
## Convierten entre los frames float de Godot y el PCM16 que usa la Live API:
##   - entrada (mic): frames @ mix_rate del proyecto → PCM16 mono @ 16 kHz
##   - salida (voz):  PCM16 mono @ 24 kHz → frames estéreo para AudioStreamGenerator

const IN_RATE := 16000   # lo que pide Gemini para el audio de entrada


## Downmix a mono + resample por interpolación lineal a 16 kHz + float→int16 LE.
## `frames` son las muestras estéreo (-1..1) que entrega AudioEffectCapture.get_buffer().
static func frames_to_pcm16_16k(frames: PackedVector2Array, src_rate: int) -> PackedByteArray:
	var out := PackedByteArray()
	var n := frames.size()
	if n == 0 or src_rate <= 0:
		return out

	var out_count := int(float(n) * IN_RATE / float(src_rate))
	if out_count <= 0:
		return out
	out.resize(out_count * 2)

	var ratio := float(src_rate) / float(IN_RATE)
	for i in out_count:
		var src_pos := float(i) * ratio
		var idx := int(src_pos)
		var frac := src_pos - float(idx)
		var a := frames[idx]
		var b := frames[mini(idx + 1, n - 1)]
		var m0 := (a.x + a.y) * 0.5
		var m1 := (b.x + b.y) * 0.5
		var s := m0 + (m1 - m0) * frac
		out.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return out


## PCM16 mono → frames estéreo float para empujar a AudioStreamGeneratorPlayback.
static func pcm16_to_frames(bytes: PackedByteArray) -> PackedVector2Array:
	var count := bytes.size() / 2
	var frames := PackedVector2Array()
	if count == 0:
		return frames
	frames.resize(count)
	for i in count:
		var f := float(bytes.decode_s16(i * 2)) / 32768.0
		frames[i] = Vector2(f, f)
	return frames


## RMS (0..1) de un bloque PCM16 — para alimentar la señal audio_level (pulso / lip-sync).
static func rms_pcm16(bytes: PackedByteArray) -> float:
	var count := bytes.size() / 2
	if count == 0:
		return 0.0
	var sum := 0.0
	for i in count:
		var f := float(bytes.decode_s16(i * 2)) / 32768.0
		sum += f * f
	return sqrt(sum / float(count))
