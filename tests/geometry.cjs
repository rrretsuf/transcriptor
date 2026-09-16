const { test } = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const path = require('node:path');

function harness() {
  const events = {};
  const area = { x: 100, y: 30, width: 1440, height: 900 };
  const electron = {
    app: { getPath: () => '/unused', requestSingleInstanceLock: () => true,
      whenReady: () => ({ then() {} }), on() {} },
    ipcMain: { on: (name, fn) => events[name] = fn, handle() {} },
    screen: { getCursorScreenPoint: () => ({}), getDisplayNearestPoint: () => ({ workArea: area }) },
  };
  const context = vm.createContext({ require: (name) => name === 'electron' ? electron : require(name),
    process, __dirname: path.resolve(__dirname, '..'), setTimeout, clearTimeout });
  vm.runInContext(fs.readFileSync(path.join(__dirname, '../main.js'), 'utf8') + `
    surface = { setBounds(b) { this.bounds = b; }, getBounds() { return this.bounds; }, webContents: { send() {} } };
    globalThis.check = { bounds: surfaceBounds, set(patch, content) { config = { ...config, ...patch }; contentHeight = content; },
      height: () => config.transcriptHeight };
  `, context);
  return { api: context.check, events, area };
}

for (const position of ['bottom', 'left', 'right']) {
  test(`${position}: content and screen bounds, stable capsule anchor`, () => {
    const { api, events, area } = harness();
    api.set({ position, transcriptVisible: false, transcriptHeight: 9999 }, 96);
    const closed = api.bounds();
    api.set({ transcriptVisible: true }, 96);
    const short = api.bounds();
    assert.equal(short.height, position === 'bottom' ? 130 : 132);
    if (position === 'bottom') {
      assert.equal(short.y + short.height, closed.y + closed.height);
      assert.equal(short.x + short.width / 2, closed.x + closed.width / 2);
    } else {
      assert.equal(short.y + short.height / 2, closed.y + closed.height / 2);
      assert.equal(position === 'left' ? short.x : short.x + short.width,
        position === 'left' ? closed.x : closed.x + closed.width);
    }
    events['surface:resize']({}, 99999);
    assert.equal(api.height(), 96);
    api.set({ transcriptHeight: 9999 }, 600);
    assert.equal(api.bounds().height, position === 'bottom' ? 634 : 600);
    api.set({}, 99999);
    const tall = api.bounds();
    assert.ok(tall.y >= area.y + 20);
    assert.ok(tall.y + tall.height <= area.y + area.height - 20);
    events['surface:resize']({}, NaN);
    assert.equal(api.height(), 9999);
  });
}
