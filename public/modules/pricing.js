export function resetTokenUsage(agent) {
  agent.tokenUsage = {
    inputTextTokens: 0,
    inputAudioTokens: 0,
    outputTextTokens: 0,
    outputAudioTokens: 0
  };
  updateTokenDisplay(agent);
}

export function getTotalTokens(agent) {
  const u = agent.tokenUsage;
  return u.inputTextTokens + u.inputAudioTokens + u.outputTextTokens + u.outputAudioTokens;
}

export function updateTokenDisplay(agent) {
  const el = agent.elements;
  el.inputTextTokens.textContent = agent.tokenUsage.inputTextTokens.toLocaleString();
  el.inputAudioTokens.textContent = agent.tokenUsage.inputAudioTokens.toLocaleString();
  el.outputTextTokens.textContent = agent.tokenUsage.outputTextTokens.toLocaleString();
  el.outputAudioTokens.textContent = agent.tokenUsage.outputAudioTokens.toLocaleString();

  el.totalTokens.textContent = getTotalTokens(agent).toLocaleString();

  if (agent.sessionData) {
    el.currentModel.textContent = agent.sessionData.model || 'Unknown';
  }

  updateCostDisplay(agent);
}

export function updateCostDisplay(agent) {
  const currentModel = agent.sessionData?.model || "gpt-realtime-mini";
  const modelPricing = agent.modelPricing[currentModel] || agent.pricing;

  const inputTextCost = (agent.tokenUsage.inputTextTokens / 1_000_000) * modelPricing.textInput;
  const inputAudioCost = (agent.tokenUsage.inputAudioTokens / 1_000_000) * modelPricing.audioInput;
  const outputTextCost = (agent.tokenUsage.outputTextTokens / 1_000_000) * modelPricing.textOutput;
  const outputAudioCost = (agent.tokenUsage.outputAudioTokens / 1_000_000) * modelPricing.audioOutput;

  agent.elements.inputTextCost.textContent = inputTextCost.toFixed(4);
  agent.elements.inputAudioCost.textContent = inputAudioCost.toFixed(4);
  agent.elements.outputTextCost.textContent = outputTextCost.toFixed(4);
  agent.elements.outputAudioCost.textContent = outputAudioCost.toFixed(4);

  const totalCost = inputTextCost + inputAudioCost + outputTextCost + outputAudioCost;
  agent.elements.totalCost.textContent = totalCost.toFixed(4);

  if (typeof agent.enforceSessionCostCap === 'function') {
    agent.enforceSessionCostCap(totalCost);
  }

  return totalCost;
}

export function updatePricingDisplay(agent) {
  const currentModel = agent.sessionData?.model || "gpt-realtime-mini";
  const modelPricing = agent.modelPricing[currentModel] || agent.pricing;

  agent.elements.priceTextInput.textContent = modelPricing.textInput.toFixed(2);
  agent.elements.priceAudioInput.textContent = modelPricing.audioInput.toFixed(2);
  agent.elements.priceTextOutput.textContent = modelPricing.textOutput.toFixed(2);
  agent.elements.priceAudioOutput.textContent = modelPricing.audioOutput.toFixed(2);

  if (agent.elements.priceTextInputCached) {
    agent.elements.priceTextInputCached.textContent = modelPricing.textInputCached.toFixed(2);
  }
  if (agent.elements.priceAudioInputCached) {
    agent.elements.priceAudioInputCached.textContent = modelPricing.audioInputCached.toFixed(2);
  }
}
