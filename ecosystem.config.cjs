module.exports = {
  apps: [{
    name: 'telegram-klavdiy',
    script: '/Users/dioteos/www/telegram-bot/start.sh',
    interpreter: '/bin/bash',
    cwd: '/Users/dioteos',
    autorestart: true,
    max_restarts: 10,
    restart_delay: 30000,
    env: {
      PATH: '/Users/dioteos/.local/bin:/Users/dioteos/.bun/bin:/Users/dioteos/.nvm/versions/node/v22.22.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin',
      HOME: '/Users/dioteos',
    },
  }],
};
