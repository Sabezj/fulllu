const path = require('path');
const webpack = require('webpack');

module.exports = {
  entry: './public/voice-agent.js', // Adjust if path differs
  output: {
    filename: 'bundle.js',
    path: path.resolve(__dirname, 'public/dist'),
  },
  module: {
    rules: [
      {
        test: /\.js$/,
        exclude: /node_modules/,
        use: {
          loader: 'babel-loader',
          options: {
            presets: ['@babel/preset-env'],
          },
        },
      },
    ],
  },
  resolve: {
              alias: {
         // «process» в исходниках → браузерная заглушка
                  dutenv:false,
             process: 'process/browser.js'
        },
      fallback: {        // Всё, что может случайно потребоваться из Node-core
               vm:   require.resolve('vm-browserify'),          // ← добавили
          os:   require.resolve('os-browserify/browser'),  // ← добавили
              buffer:      require.resolve('buffer/'),
              stream:      require.resolve('stream-browserify'),
              crypto:      require.resolve('crypto-browserify'),
             util:        require.resolve('util/'),
              assert:      require.resolve('assert/'),
              path: false,
              fs:   false,
              // главное:
                  process:     require.resolve('process/browser.js')
       }
   },
   plugins: [
        // автоподставляем process и Buffer там, где они встречаются
            new webpack.ProvidePlugin({
                  process: 'process/browser.js',
            Buffer:  ['buffer', 'Buffer']
      })
   ],
  mode: 'development',
  // Suppress non-critical warnings (optional)
  ignoreWarnings: [
    /Critical dependency/,
    /the request of a dependency is an expression/
  ],
  // Detailed error stats
  stats: {
    errorDetails: true,
  },
};
