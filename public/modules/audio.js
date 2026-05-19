const logger = window.logger || console;

export async function setupInputAudioAnalysis(agent) {
  agent.audioContext = new (window.AudioContext || window.webkitAudioContext)();
  if (agent.audioContext.state === 'suspended') {
    try {
      await agent.audioContext.resume();
    } catch (err) {
      agent.log('error', `AudioContext resume failed: ${err.message}`);
    }
  }
  const source = agent.audioContext.createMediaStreamSource(agent.mediaStream);

  agent.inputAnalyser = agent.audioContext.createAnalyser();
  agent.inputAnalyser.fftSize = 256;
  agent.inputAnalyser.smoothingTimeConstant = 0.8;

  source.connect(agent.inputAnalyser);
  agent.inputLevelData = new Uint8Array(agent.inputAnalyser.frequencyBinCount);
}

export async function setupOutputAudioAnalysis(agent, stream) {
  try {
    if (!(stream instanceof MediaStream)) {
      throw new Error('No valid output MediaStream received');
    }

    if (agent.audioContext?.state === 'suspended') {
      await agent.audioContext.resume();
    }

    if (agent.outputSourceNode) {
      try { agent.outputSourceNode.disconnect(); } catch {}
      agent.outputSourceNode = null;
    }
    if (agent.outputFallbackGainNode) {
      try { agent.outputFallbackGainNode.disconnect(); } catch {}
      agent.outputFallbackGainNode = null;
    }

    agent.outputAudioElement = new Audio();
    agent.outputAudioElement.srcObject = stream;
    agent.outputAudioElement.autoplay = true;
    agent.outputAudioElement.muted = false;
    agent.outputAudioElement.playsInline = true;

    const outputSource = agent.audioContext.createMediaStreamSource(stream);
    agent.outputAnalyser = agent.audioContext.createAnalyser();
    agent.outputAnalyser.fftSize = 256;
    agent.outputAnalyser.smoothingTimeConstant = 0.8;

    outputSource.connect(agent.outputAnalyser);
    agent.outputSourceNode = outputSource;
    agent.outputLevelData = new Uint8Array(agent.outputAnalyser.frequencyBinCount);

    const enableFallbackPlayback = () => {
      if (agent.outputFallbackGainNode) return;
      const gain = agent.audioContext.createGain();
      gain.gain.value = 1.0;
      outputSource.connect(gain);
      gain.connect(agent.audioContext.destination);
      agent.outputFallbackGainNode = gain;
      agent.log('system', 'Using AudioContext fallback for output playback');
    };

    try {
      await agent.outputAudioElement.play();
    } catch (playError) {
      agent.log('error', `Output audio autoplay blocked: ${playError.message}`);
      enableFallbackPlayback();
    }

    agent.log('system', 'Output audio analysis setup complete');
  } catch (error) {
    agent.log('error', `Output audio setup failed: ${error.message}`);
  }
}

export function drawVisualization(agent) {
  const canvas = document.getElementById('audio-canvas');
  const ctx = canvas.getContext('2d');

  ctx.fillStyle = '#1e293b';
  ctx.fillRect(0, 0, canvas.width, canvas.height);

  if (agent.inputAnalyser && agent.outputAnalyser) {
    const inputData = new Uint8Array(agent.inputAnalyser.frequencyBinCount);
    const outputData = new Uint8Array(agent.outputAnalyser.frequencyBinCount);
    agent.inputAnalyser.getByteFrequencyData(inputData);
    agent.outputAnalyser.getByteFrequencyData(outputData);

    agent.inputLevelData = inputData;
    agent.outputLevelData = outputData;

    const halfWidth = canvas.width / 2 - 10;
    drawWaveform(ctx, inputData, 0, halfWidth, canvas.height, '#007BFF', 'Input');
    drawWaveform(ctx, outputData, halfWidth + 20, halfWidth, canvas.height, '#6C757D', 'Output');

    const inputLevel = getAudioLevel(inputData);
    const outputLevel = getAudioLevel(outputData);
    updateLevelMeter('input-level', inputLevel);
    updateLevelMeter('output-level', outputLevel);

    detectVoiceActivity(agent, inputLevel);
  }

  requestAnimationFrame(() => drawVisualization(agent));
}

export function drawWaveform(ctx, data, x, width, height, color, label) {
  const barWidth = width / data.length;
  const centerY = height / 2;

  ctx.fillStyle = color;
  ctx.globalAlpha = 0.7;

  for (let i = 0; i < data.length; i++) {
    const barHeight = (data[i] / 255) * (height * 0.8);
    const barX = x + i * barWidth;
    ctx.fillRect(barX, centerY - barHeight / 2, barWidth - 1, barHeight);
  }

  ctx.globalAlpha = 1;
  ctx.fillStyle = '#64748b';
  ctx.font = '12px Arial, sans-serif';
  ctx.textAlign = 'center';
  ctx.fillText(label, x + width / 2, height - 10);
}

export function getAudioLevel(data) {
  let sum = 0;
  for (let i = 0; i < data.length; i++) {
    sum += data[i];
  }
  return (sum / data.length) / 255;
}

export function updateLevelMeter(elementId, level) {
  const meter = document.getElementById(elementId);
  if (meter) {
    meter.style.width = `${level * 100}%`;
  }
}

export function detectVoiceActivity(agent, inputLevel) {
  const now = Date.now();
  const responseAgeMs = agent.lastResponseCreatedAt ? (now - agent.lastResponseCreatedAt) : 0;
  const canInterrupt =
    agent.hasActiveResponse &&
    agent.isAssistantSpeaking &&
    responseAgeMs >= (agent.minInterruptResponseAgeMs || 0);

  if (Date.now() - agent.lastVoiceActivityCheck > 500) {
    logger.debug('Voice Activity Debug:', {
      inputLevel: inputLevel.toFixed(4),
      threshold: agent.voiceActivityThreshold,
      aboveThreshold: inputLevel > agent.voiceActivityThreshold,
      duration: agent.voiceActivityDuration,
      isAssistantSpeaking: agent.isAssistantSpeaking,
      hasActiveResponse: agent.hasActiveResponse,
      responseAgeMs,
      interruptionEnabled: canInterrupt
    });
    agent.lastVoiceActivityCheck = Date.now();
  }

  if (!canInterrupt) {
    agent.voiceActivityDuration = 0;
    return;
  }

  if (inputLevel > agent.voiceActivityThreshold) {
    agent.voiceActivityDuration++;

    if (agent.voiceActivityDuration >= agent.voiceActivityCountThreshold) {
      agent.log('system', '🗣️ User voice detected during AI response - interrupting AI');
      agent.agentLog('User voice detected during AI response - interrupting AI');
      logger.debug('INTERRUPTING AI:', {
        duration: agent.voiceActivityDuration,
        threshold: agent.voiceActivityCountThreshold,
      });
      agent.sendEvent({ type: 'response.cancel' });
      agent.hasActiveResponse = false;
      agent.voiceActivityDuration = 0;
    }
  } else {
    agent.voiceActivityDuration = 0;
  }
}
