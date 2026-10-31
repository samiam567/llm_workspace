
from litellm.integrations.custom_logger import CustomLogger


class RoutingLogger(CustomLogger):

    def __init__(self):
        super().__init__()

    def get_model_name(self, response, fallback="unknown"):
        """Get the actual provider model from the response."""
        model = getattr(response, "model", None)

        if not model and isinstance(response, dict):
            model = response.get("model")

        return model or fallback

    def set_actual_model(self, response, model):
        if not model:
            return response

        try:
            if isinstance(response, dict):
                response["model"] = model
            elif hasattr(response, "model"):
                response.model = model
        except Exception as e:
            print(f"[MODEL_NAME] Could not set model: {e}", flush=True)

        return response

    def prefix_response(self, response, model):
        """Prefix the first assistant text response."""

        if not model or model == "unknown":
            print("[MODEL_PREFIX] No actual model name found", flush=True)
            return response

        prefix = f"**_{model}:_**\n "

        try:
            choices = (
                response.get("choices", [])
                if isinstance(response, dict)
                else response.choices
            )

            if not choices:
                return response

            choice = choices[0]

            message = (
                choice.get("message", {})
                if isinstance(choice, dict)
                else choice.message
            )

            content = (
                message.get("content")
                if isinstance(message, dict)
                else message.content
            )

            # Do not modify tool calls or non-text responses.
            tool_calls = (
                message.get("tool_calls")
                if isinstance(message, dict)
                else getattr(message, "tool_calls", None)
            )

            if tool_calls or not isinstance(content, str) or not content:
                return response

            if not content.startswith(prefix):
                if isinstance(message, dict):
                    message["content"] = prefix + content
                else:
                    message.content = prefix + content

            print(f"[MODEL_PREFIX] Added prefix: {model}", flush=True)

        except Exception as e:
            print(f"[MODEL_PREFIX] Error: {e}", flush=True)

        return response

    async def async_pre_call_deployment_hook(self, kwargs, call_type):
        model = kwargs.get("model", "unknown")

        print(
            f"[ROUTER] SENDING model={model} "
            f"call_type={call_type}",
            flush=True,
        )

        return None

    # PROXY HOOK: Non-streaming responses
    async def async_post_call_success_hook(
        self, data, user_api_key_dict, response
    ):
        model = self.get_model_name(response)

        return self.prefix_response(response, model)

    # PROXY HOOK: Streaming responses
    async def async_post_call_streaming_iterator_hook(
        self, user_api_key_dict, response, request_data
    ):
        prefixed = False

        async for chunk in response:
            if not prefixed:
                model = self.get_model_name(chunk)

                if model != "unknown":
                    try:
                        choices = (
                            chunk.get("choices", [])
                            if isinstance(chunk, dict)
                            else chunk.choices
                        )

                        if choices:
                            choice = choices[0]

                            delta = (
                                choice.get("delta", {})
                                if isinstance(choice, dict)
                                else choice.delta
                            )

                            content = (
                                delta.get("content")
                                if isinstance(delta, dict)
                                else getattr(delta, "content", None)
                            )

                            if isinstance(content, str) and content:
                                prefix = f"**_{model}:_**\n "

                                if isinstance(delta, dict):
                                    delta["content"] = prefix + content
                                else:
                                    delta.content = prefix + content

                                prefixed = True

                                print(
                                    f"[MODEL_PREFIX] Streaming prefix: {model}",
                                    flush=True,
                                )

                    except Exception as e:
                        print(
                            f"[MODEL_PREFIX] Stream error: {e}",
                            flush=True,
                        )

            yield chunk

    # Existing deployment success logging
    async def async_post_call_success_deployment_hook(
        self, request_data, response, call_type
    ):
        model = request_data.get("model", "unknown")

        # Preserve the full LiteLLM deployment name.
        self.set_actual_model(response, model)

        green = "\033[92m"
        reset = "\033[0m"

        print(
            f"[SUCCESS_RESULT] model={green}{model}{reset} "
            f"call_type={call_type}",
            flush=True,
        )

        return response

    # Existing failure logging
    async def async_post_call_failure_deployment_hook(
        self,
        request_data,
        exception,
        call_type,
        fallback_depth=None,
    ):
        model = request_data.get("model", "unknown")

        error_type = type(exception).__name__
        error_message = str(exception).replace("\n", " ")[:500]

        print(
            f"[FAILURE] model={model} "
            f"error_type={error_type} "
            f"fallback_depth={fallback_depth} "
            f"call_type={call_type} "
            f"message={error_message}",
            flush=True,
        )


proxy_handler_instance = RoutingLogger()
