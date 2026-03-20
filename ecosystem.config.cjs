const os = require('os');
const path = require('path');

const home = os.homedir();

module.exports = {
  apps: [{
    name: 'telegram-klavdiy',
    script: path.join(__dirname, 'start.sh'),
    interpreter: '/bin/bash',
    cwd: home,
    autorestart: true,
    max_restarts: 10,
    restart_delay: 30000,
    env: {
      HOME: home,
    },
  }],
};
