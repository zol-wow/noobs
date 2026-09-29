// macOS smoke test for buffered recording. Captures the main display
// plus system audio into the replay buffer, converts it to a recording
// with a pre-roll offset, and checks the result with ffprobe.
//
// Needs Screen Recording permission for the terminal running node.
const noobs = require('../index.js');
const path = require('path');
const fs = require('fs');
const { execFileSync } = require('child_process');

const PRE_ROLL = 5; // seconds of buffer to keep when converting
const BUFFER_TIME = 10; // seconds to buffer before converting
const RECORD_TIME = 5; // seconds to record after converting

const sleep = (s) => new Promise((resolve) => setTimeout(resolve, s * 1000));

const signals = [];
const waitForSignal = async (id, timeout = 30) => {
  for (let i = 0; i < timeout * 10; i++) {
    const idx = signals.findIndex((s) => s.id === id);
    if (idx !== -1) return signals.splice(idx, 1)[0];
    await sleep(0.1);
  }
  throw new Error(`Timed out waiting for signal ${id}`);
};

async function test() {
  const distPath = path.resolve(__dirname, '../dist');
  const logPath = path.resolve(__dirname, '../logs');
  const recordingPath = path.resolve(__dirname, '../recordings');
  fs.mkdirSync(recordingPath, { recursive: true });

  noobs.Init(distPath, logPath, (signal) => {
    if (signal.type !== 'volmeter') {
      console.log('Signal:', signal);
      signals.push(signal);
    }
  });

  noobs.SetBuffering(true);
  noobs.SetRecordingCfg(recordingPath, 'mp4');
  noobs.ResetVideoContext(60, 1920, 1080);

  const encoders = noobs.ListVideoEncoders();
  console.log('Encoders:', encoders);
  const vt = encoders.find((e) => e.includes('videotoolbox') && e.includes('avc'));
  noobs.SetVideoEncoder(vt || 'obs_x264', {});

  const display = noobs.CreateSource('Display', 'screen_capture');
  const displaySettings = noobs.GetSourceSettings(display);
  noobs.SetSourceSettings(display, { ...displaySettings, type: 0 });
  noobs.AddSourceToScene(display);

  const audio = noobs.CreateSource('Desktop Audio', 'sck_audio_capture');
  const audioSettings = noobs.GetSourceSettings(audio);
  noobs.SetSourceSettings(audio, { ...audioSettings, type: 0 });
  noobs.AddSourceToScene(audio);

  console.log('Starting buffer');
  noobs.StartBuffer();
  await waitForSignal('start');
  await sleep(BUFFER_TIME);

  console.log(`Converting buffer with ${PRE_ROLL}s pre-roll`);
  noobs.StartRecording(PRE_ROLL);
  const converted = await waitForSignal('converted');
  console.log('Converted:', converted);
  await sleep(RECORD_TIME);

  console.log('Stopping recording');
  noobs.StopRecording();
  await waitForSignal('stop');

  const file = noobs.GetLastRecording();
  noobs.Shutdown();

  const ffprobe = path.join(distPath, 'Frameworks', 'ffprobe');
  const probe = JSON.parse(
    execFileSync(ffprobe, [
      '-v', 'error',
      '-show_entries', 'format=duration:stream=codec_type,codec_name,width,height',
      '-of', 'json',
      file,
    ]).toString(),
  );

  console.log('Recording:', file);
  console.log(JSON.stringify(probe, null, 2));

  const duration = Number(probe.format.duration);
  const expected = PRE_ROLL + RECORD_TIME;
  const hasVideo = probe.streams.some((s) => s.codec_type === 'video');
  const hasAudio = probe.streams.some((s) => s.codec_type === 'audio');

  // Pre-roll snaps to the nearest keyframe, so allow some slack.
  if (!hasVideo || !hasAudio || Math.abs(duration - expected) > 2.5) {
    console.error(`FAILED: duration ${duration}s (expected ~${expected}s), video ${hasVideo}, audio ${hasAudio}`);
    process.exit(1);
  }

  console.log(`PASSED: ${duration}s recording with ${PRE_ROLL}s pre-roll`);
}

test().catch((err) => {
  console.error(err);
  process.exit(1);
});
