package com.hydra.android.feature.orchs

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DeleteOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.hydra.android.core.designsystem.HydraCard
import com.hydra.android.core.model.AIModelReference
import com.hydra.android.core.model.AgentChatTarget
import com.hydra.android.core.model.OrchAIAgent
import com.hydra.android.core.model.OrchAIAgents
import com.hydra.android.core.model.OrchAIConnection
import java.util.UUID

/** Stateless entry point also used by device tests, without Hilt or a live API. */
@Composable
fun OrchAgentsCard(
    orchestrationId: String,
    orchestrationName: String,
    state: OrchAgentsUiState,
    canSwitchAgent: Boolean,
    onConfigure: () -> Unit,
    onRetry: () -> Unit,
    onOpenAgentChat: (AgentChatTarget) -> Unit,
    modifier: Modifier = Modifier,
) {
    HydraCard(modifier.testTag("orch-ai-agents-section")) {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("AI 에이전트", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            TextButton(
                onClick = onConfigure,
                enabled = !state.isLoading && state.loadError == null,
                modifier = Modifier.testTag("orch-ai-agents-configure"),
            ) { Text("설정") }
        }
        when {
            state.isLoading -> CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
            state.loadError != null -> {
                Text(state.loadError, color = MaterialTheme.colorScheme.error)
                TextButton(onClick = onRetry, modifier = Modifier.testTag("orch-ai-agents-retry")) {
                    Text("다시 시도")
                }
            }
            else -> {
                Text(
                    "헤드 모델: ${state.configuration.headModel?.let(state.configuration::label) ?: "전역 AI 설정 사용"}",
                    style = MaterialTheme.typography.bodySmall,
                )
                if (state.configuration.agents.isEmpty()) {
                    Text(
                        "이 오케스트레이션에서 사용할 모델 연결과 역할별 에이전트를 추가하세요.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                }
                state.configuration.agents.forEach { agent ->
                    HorizontalDivider(Modifier.padding(vertical = 8.dp))
                    Text(agent.name, style = MaterialTheme.typography.titleSmall)
                    Text(agent.role, style = MaterialTheme.typography.bodySmall, maxLines = 3)
                    Text(
                        agent.modelOverride?.let { "고정 모델: ${state.configuration.label(it)}" } ?: "헤드에게 맡김",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedButton(
                        onClick = {
                            onOpenAgentChat(agentChatTarget(orchestrationId, orchestrationName, agent, state.configuration))
                        },
                        enabled = canSwitchAgent,
                        modifier = Modifier.testTag("orch-agent-chat-${agent.id}"),
                    ) { Text("에이전트와 대화") }
                }
                if (!canSwitchAgent) {
                    Text(
                        "대기 중인 계획을 실행하거나 취소하고 현재 요청이 끝나면 에이전트를 전환할 수 있습니다.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                } else if (state.configuration.agents.isNotEmpty()) {
                    Text(
                        "에이전트를 전환하면 새 대화를 시작합니다.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

internal fun agentChatTarget(
    orchestrationId: String,
    orchestrationName: String,
    agent: OrchAIAgent,
    configuration: OrchAIAgents,
) = AgentChatTarget(orchestrationId, orchestrationName, agent, agent.modelOverride?.let(configuration::label))

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun OrchAgentsEditor(
    orchestrationName: String,
    original: OrchAIAgents,
    draft: OrchAIAgents,
    isSaving: Boolean,
    saveError: String?,
    onDraftChange: (OrchAIAgents) -> Unit,
    onSave: () -> Unit,
    onCancel: () -> Unit,
) {
    val errors = draft.validationErrors(original)
    Scaffold(
        modifier = Modifier.fillMaxSize().testTag("orch-ai-agents-editor"),
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text("AI 에이전트 설정", style = MaterialTheme.typography.titleMedium)
                        Text(orchestrationName, style = MaterialTheme.typography.bodySmall, maxLines = 1)
                    }
                },
                navigationIcon = {
                    TextButton(onClick = onCancel, enabled = !isSaving, modifier = Modifier.testTag("orch-ai-agents-cancel")) {
                        Text("취소")
                    }
                },
                actions = {
                    if (isSaving) CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
                    TextButton(
                        onClick = onSave,
                        enabled = !isSaving && errors.isEmpty(),
                        modifier = Modifier.testTag("orch-ai-agents-save"),
                    ) { Text("저장") }
                },
            )
        },
    ) { padding ->
        Column(
            Modifier.padding(padding).verticalScroll(rememberScrollState()).padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            Text("모델 연결", style = MaterialTheme.typography.titleMedium)
            Text(
                "계정에서 사용할 수 있는 정확한 모델 ID를 입력하세요. 연결 하나에 여러 모델을 추가할 수 있습니다.",
                style = MaterialTheme.typography.bodySmall,
            )
            Text(
                "API 키는 서버에 보관됩니다. 연결 ID·제공자·엔드포인트가 같으면 키를 비워 두어 저장된 키를 유지할 수 있습니다.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            draft.connections.forEachIndexed { index, connection ->
                key(connection.id, index) {
                    ConnectionEditor(
                        connection = connection,
                        original = original,
                        enabled = !isSaving,
                        onChange = { changed -> onDraftChange(draft.copy(connections = draft.connections.toMutableList().also { it[index] = changed })) },
                        onRemove = { onDraftChange(draft.copy(connections = draft.connections.filterIndexed { i, _ -> i != index })) },
                    )
                }
            }
            OutlinedButton(
                onClick = {
                    onDraftChange(draft.copy(connections = draft.connections + OrchAIConnection(
                        id = UUID.randomUUID().toString(), name = "", provider = "claude", endpoint = "", models = listOf(""),
                    )))
                },
                enabled = !isSaving,
                modifier = Modifier.testTag("orch-add-connection"),
            ) { Text("연결 추가") }

            HydraCard {
                Text("헤드 모델", style = MaterialTheme.typography.titleSmall)
                ModelPicker(
                    value = draft.headModel, configuration = draft, automaticTitle = "전역 AI 설정 사용",
                    enabled = !isSaving, tag = "orch-head-model",
                    onChange = { onDraftChange(draft.copy(headModel = it)) },
                )
                Text(
                    "헤드는 역할과 작업에 맞춰 연결된 모델을 선택합니다. 에이전트에 고정 모델을 지정하면 해당 모델을 사용합니다.",
                    style = MaterialTheme.typography.bodySmall,
                )
            }

            Text("에이전트", style = MaterialTheme.typography.titleMedium)
            draft.agents.forEachIndexed { index, agent ->
                key(agent.id, index) {
                    HydraCard {
                        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                            Text("에이전트 ${index + 1}", modifier = Modifier.weight(1f), style = MaterialTheme.typography.titleSmall)
                            IconButton(
                                onClick = { onDraftChange(draft.copy(agents = draft.agents.filterIndexed { i, _ -> i != index })) },
                                enabled = !isSaving, modifier = Modifier.testTag("orch-remove-agent-${agent.id}"),
                            ) { Icon(Icons.Default.DeleteOutline, contentDescription = "에이전트 삭제") }
                        }
                        fun updateAgent(changed: OrchAIAgent) = onDraftChange(
                            draft.copy(agents = draft.agents.toMutableList().also { it[index] = changed })
                        )
                        OutlinedTextField(
                            value = agent.name, onValueChange = { updateAgent(agent.copy(name = it)) },
                            label = { Text("에이전트 이름") }, singleLine = true, enabled = !isSaving,
                            modifier = Modifier.fillMaxWidth().testTag("orch-agent-name-${agent.id}"),
                        )
                        OutlinedTextField(
                            value = agent.role, onValueChange = { updateAgent(agent.copy(role = it)) },
                            label = { Text("역할 지침") }, minLines = 2, maxLines = 6, enabled = !isSaving,
                            modifier = Modifier.fillMaxWidth().padding(top = 8.dp).testTag("orch-agent-role-${agent.id}"),
                        )
                        ModelPicker(
                            value = agent.modelOverride, configuration = draft, automaticTitle = "헤드에게 맡김",
                            enabled = !isSaving, tag = "orch-agent-model-${agent.id}",
                            onChange = { updateAgent(agent.copy(modelOverride = it)) },
                        )
                    }
                }
            }
            OutlinedButton(
                onClick = { onDraftChange(draft.copy(agents = draft.agents + OrchAIAgent(id = UUID.randomUUID().toString(), name = "", role = ""))) },
                enabled = !isSaving, modifier = Modifier.testTag("orch-add-agent"),
            ) { Text("에이전트 추가") }
            if (errors.isNotEmpty()) {
                Column(Modifier.testTag("orch-ai-agents-validation"), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    errors.forEach { Text(validationMessage(it), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.error) }
                }
            }
            saveError?.let {
                Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.testTag("orch-ai-agents-save-error"))
            }
        }
    }
}

@Composable
private fun ConnectionEditor(
    connection: OrchAIConnection,
    original: OrchAIAgents,
    enabled: Boolean,
    onChange: (OrchAIConnection) -> Unit,
    onRemove: () -> Unit,
) {
    val retainedKey = original.connections.any {
        it.id == connection.id && it.provider == connection.provider && it.endpoint == connection.endpoint && it.hasApiKey
    }
    HydraCard {
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
            Text("모델 연결", style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f))
            IconButton(onClick = onRemove, enabled = enabled, modifier = Modifier.testTag("orch-remove-connection-${connection.id}")) {
                Icon(Icons.Default.DeleteOutline, contentDescription = "연결 삭제")
            }
        }
        OutlinedTextField(
            value = connection.name, onValueChange = { onChange(connection.copy(name = it)) },
            label = { Text("연결 이름") }, singleLine = true, enabled = enabled,
            modifier = Modifier.fillMaxWidth().testTag("orch-connection-name-${connection.id}"),
        )
        var providerExpanded by remember { mutableStateOf(false) }
        Box {
            OutlinedButton(
                onClick = { providerExpanded = true }, enabled = enabled,
                modifier = Modifier.fillMaxWidth().padding(top = 8.dp).testTag("orch-connection-provider-${connection.id}"),
            ) { Text("제공자: ${providers[connection.provider] ?: connection.provider}") }
            DropdownMenu(expanded = providerExpanded, onDismissRequest = { providerExpanded = false }) {
                providers.forEach { (provider, name) ->
                    DropdownMenuItem(
                        text = { Text(name) },
                        onClick = {
                            providerExpanded = false
                            onChange(connection.copy(provider = provider, apiKey = if (provider == connection.provider) connection.apiKey else null))
                        },
                    )
                }
            }
        }
        OutlinedTextField(
            value = connection.endpoint,
            onValueChange = { onChange(connection.copy(endpoint = it, apiKey = null)) },
            label = { Text("엔드포인트 URL") },
            supportingText = { Text("클라우드는 선택 사항, 로컬 연결은 필수") },
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
            singleLine = true, enabled = enabled,
            modifier = Modifier.fillMaxWidth().testTag("orch-connection-endpoint-${connection.id}"),
        )
        OutlinedTextField(
            value = connection.apiKey.orEmpty(), onValueChange = { onChange(connection.copy(apiKey = it.ifEmpty { null })) },
            label = { Text("API 키") }, visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password),
            singleLine = true, enabled = enabled,
            modifier = Modifier.fillMaxWidth().testTag("orch-connection-key-${connection.id}"),
        )
        Text(
            if (retainedKey) "저장된 키가 있습니다. 비워 두면 유지됩니다."
            else if (connection.provider in setOf("claude", "openai", "zai")) "새 연결이나 변경된 연결에는 API 키가 필요합니다."
            else "인증이 필요한 엔드포인트라면 API 키를 입력하세요.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(vertical = 8.dp),
        )
        Text("정확한 모델 ID", style = MaterialTheme.typography.titleSmall)
        connection.models.forEachIndexed { index, model ->
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                OutlinedTextField(
                    value = model,
                    onValueChange = { value -> onChange(connection.copy(models = connection.models.toMutableList().also { it[index] = value })) },
                    label = { Text("모델 ID ${index + 1}") }, singleLine = true, enabled = enabled,
                    modifier = Modifier.weight(1f).testTag("orch-connection-model-${connection.id}-$index"),
                )
                IconButton(
                    onClick = { onChange(connection.copy(models = connection.models.filterIndexed { i, _ -> i != index })) },
                    enabled = enabled, modifier = Modifier.testTag("orch-remove-model-${connection.id}-$index"),
                ) { Icon(Icons.Default.DeleteOutline, contentDescription = "모델 ID 삭제") }
            }
        }
        TextButton(
            onClick = { onChange(connection.copy(models = connection.models + "")) }, enabled = enabled,
            modifier = Modifier.testTag("orch-add-model-${connection.id}"),
        ) { Text("모델 ID 추가") }
    }
}

@Composable
private fun ModelPicker(
    value: AIModelReference?,
    configuration: OrchAIAgents,
    automaticTitle: String,
    enabled: Boolean,
    tag: String,
    onChange: (AIModelReference?) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        OutlinedButton(
            onClick = { expanded = true }, enabled = enabled,
            modifier = Modifier.fillMaxWidth().padding(vertical = 8.dp).testTag(tag),
        ) {
            Text(value?.let { reference ->
                if (configuration.contains(reference)) configuration.label(reference) else "삭제된 모델: ${reference.model}"
            } ?: automaticTitle)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, modifier = Modifier.heightIn(max = 320.dp)) {
            DropdownMenuItem(text = { Text(automaticTitle) }, onClick = { expanded = false; onChange(null) })
            configuration.modelReferences.distinct().forEach { reference ->
                DropdownMenuItem(
                    text = { Text(configuration.label(reference)) },
                    onClick = { expanded = false; onChange(reference) },
                )
            }
        }
    }
}

private val providers = linkedMapOf(
    "claude" to "Claude", "openai" to "OpenAI", "zai" to "Z.AI",
    "ollama" to "Ollama", "lmstudio" to "LM Studio", "openai_compatible" to "OpenAI 호환",
)

private fun validationMessage(message: String): String = when (message) {
    "Agent and connection IDs must be unique." -> "에이전트와 연결 ID는 각각 고유해야 합니다."
    "Give every connection a name and ID." -> "모든 연결에 이름과 ID가 필요합니다."
    "Choose a supported provider." -> "지원되는 제공자를 선택하세요."
    "Enter at least one exact model ID for each connection." -> "연결마다 정확한 모델 ID를 하나 이상 입력하세요."
    "Model IDs must be unique within a connection." -> "같은 연결에 모델 ID를 중복해서 입력할 수 없습니다."
    "Remove leading or trailing spaces from model IDs." -> "모델 ID 앞뒤의 공백을 제거하세요."
    "Enter an API key for each new or changed cloud connection." -> "새 클라우드 연결이나 변경된 연결의 API 키를 입력하세요."
    "Enter an HTTP or HTTPS endpoint without embedded credentials." -> "인증 정보·쿼리·프래그먼트가 없는 HTTP 또는 HTTPS 엔드포인트를 입력하세요."
    "Select an available head model or use global AI settings." -> "사용 가능한 헤드 모델 또는 전역 AI 설정을 선택하세요."
    "Give every agent a name, ID and role instructions." -> "모든 에이전트에 이름·ID·역할 지침이 필요합니다."
    "An agent refers to a removed connection or model. Choose another model or let the head decide." -> "삭제된 연결이나 모델을 참조하는 에이전트가 있습니다. 다른 모델 또는 '헤드에게 맡김'을 선택하세요."
    "Add at least one model for the head to assign to agents." -> "헤드가 에이전트에 배정할 모델을 하나 이상 추가하세요."
    else -> message
}
