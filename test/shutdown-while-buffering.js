// Shutting down while the buffer is active force stops the output, which
// emits signals during teardown. This used to crash.
const noobs = require('../index.js');
const path = require('path');

const capture = process.platform === 'darwin' ? 'screen_capture' : 'monitor_capture';

noobs.Init(path.resolve(__dirname, '../dist'), path.resolve(__dirname, '../logs'), () => {});
noobs.SetBuffering(true);
noobs.SetRecordingCfg(path.resolve(__dirname, '../recordings'), 'mp4');
noobs.AddSourceToScene(noobs.CreateSource('Capture', capture));
noobs.StartBuffer();

setTimeout(() => {
  noobs.Shutdown();
  console.log('PASSED: shut down while buffering');
}, 3000);
