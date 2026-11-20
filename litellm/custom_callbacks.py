
from litellm.integrations.custom_logger import CustomLogger


ACTUAL_MODEL_PREFIX = "owui_actual_model:"


class RoutingLogger(CustomLogger):

    def __init__(self):
        super().__init__()

    def get_model_name(self, response, fallback="unknown"):
        """Read the model name from a LiteLLM response."""

        model = getattr(response, "model", None)

        if not model and isinstance(response, dict):
            model = response.get("model")

        return model or fallback

    def normalize_model_name(self, model):
        """Remove the LiteLLM provider prefix for display."""

        if not model or model == "unknown":
            return "unknown"

        if model.startswith("openrouter/"):
            model = model[len("openrouter/"):]

        return model

    def set_actual_model(self, chunk, model):
        """
        Attach the actual deployment to the streaming chunk.

        model:
            Standard OpenAI-compatible model field.

        system_fingerprint:
            Dedicated marker consumed by the Open WebUI filter.
        """

        model = self.normalize_model_name(model)

        if model == "unknown":
            return chunk

        try:
            fingerprint = f"{ACTUAL_MODEL_PREFIX}{model}"

            if isinstance(chunk, dict):
                chunk["model"] = model
                chunk["system_fingerprint"] = fingerprint
            else:
                chunk.model = model
                chunk.system_fingerprint = fingerprint

        except Exception as e:
            print(
                f"[MODEL_NAME] Could not update chunk: {e}",
                flush=True,
            )

        return chunk

    # Log selected deployment before each attempt
    async def async_pre_call_deployment_hook(self, kwargs, call_type):

        model = kwargs.get("model", "unknown")

        print(
            f"[ROUTER] SENDING model={model} "
            f"call_type={call_type}",
            flush=True,
        )

        return None

    # Successful deployment
    async def async_post_call_success_deployment_hook(
        self, request_data, response, call_type
    ):

        requested_model = request_data.get("model", "unknown")
        response_model = self.get_model_name(response)

        print(
            f"[DEPLOYMENT_DEBUG] "
            f"request_model={requested_model} "
            f"response_model={response_model} "
            f"request_keys={list(request_data.keys())}",
            flush=True,
        )

        green = "\033[92m"
        reset = "\033[0m"

        print(
            f"[SUCCESS_RESULT] model={green}{requested_model}{reset} "
            f"call_type={call_type}",
            flush=True,
        )

        return response

    # Non-streaming response
    async def async_post_call_success_hook(
        self, data, user_api_key_dict, response
    ):
        return response

    # Modify each deployment's streaming chunk
    async def async_post_call_streaming_deployment_hook(
        self,
        request_data,
        response_chunk,
        call_type,
    ):

        # This is the actual deployment used for this attempt.
        model = request_data.get("model", "unknown")

        self.set_actual_model(response_chunk, model)

        normalized_model = self.normalize_model_name(model)

        print(
            f"[STREAM_DEPLOYMENT_HOOK] "
            f"actual_model={normalized_model} "
            f"chunk_type={type(response_chunk).__name__}",
            flush=True,
        )

        return response_chunk

    # Final streaming iterator
    async def async_post_call_streaming_iterator_hook(
        self, user_api_key_dict, response, request_data
    ):

        # The upstream wrapper contains the selected provider model.
        actual_model = self.normalize_model_name(
            self.get_model_name(response)
        )

        print(
            f"[STREAM_MODEL] Final stream model: {actual_model} "
            f"wrapper={type(response).__name__}",
            flush=True,
        )

        async for chunk in response:

            if actual_model != "unknown":
                self.set_actual_model(chunk, actual_model)

            yield chunk

    # Expose the model as an HTTP response header too
    async def async_post_call_response_headers_hook(
        self,
        data,
        user_api_key_dict,
        response,
        request_headers=None,
    ):

        model = self.normalize_model_name(
            self.get_model_name(response)
        )

        if model == "unknown":
            return {}

        headers = {
            "X-LiteLLM-Actual-Model": model
        }

        print(
            f"[MODEL_HEADER_DEBUG] Returning headers: {headers}",
            flush=True,
        )

        return headers

    # Failure logging
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
