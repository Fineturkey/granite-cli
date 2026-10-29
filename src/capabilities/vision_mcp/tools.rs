//! MCP tool definitions exposing a `VlmBackend` over `rmcp`'s `#[tool]`/
//! `#[tool_router]` macros.

use crate::capabilities::vision_mcp::backend::{AnalysisType, ImageSource, VlmBackend};
use base64::Engine;
use rmcp::{
    ErrorData, handler::server::wrapper::Parameters, model::ErrorCode, schemars, tool, tool_router,
};
use std::sync::Arc;
use url::Url;

/*-- ImageSource parsing -----------------------------------------------------------*/

trait ParseImage {
    fn source_type(&self) -> &str;
    fn image(&self) -> &str;

    fn parse_image(&self) -> Result<ImageSource, ErrorData> {
        match self.source_type() {
            "file" => Ok(ImageSource::File(std::path::PathBuf::from(self.image()))),
            "base64" => {
                let data = base64::engine::general_purpose::STANDARD
                    .decode(self.image())
                    .map_err(|e| {
                        ErrorData::new(
                            ErrorCode::INVALID_PARAMS,
                            format!("Invalid base64: {e}"),
                            None,
                        )
                    })?;
                Ok(ImageSource::Bytes {
                    data,
                    mime: "image/jpeg".to_string(),
                })
            }
            "url" => {
                let url = Url::parse(self.image()).map_err(|e| {
                    ErrorData::new(ErrorCode::INVALID_PARAMS, format!("Invalid URL: {e}"), None)
                })?;
                Ok(ImageSource::Url(url))
            }
            other => Err(ErrorData::new(
                ErrorCode::INVALID_PARAMS,
                format!("Unknown image source type: '{other}'. Use 'file', 'base64', or 'url'."),
                None,
            )),
        }
    }
}

macro_rules! impl_parse_image {
    ($ty:ty) => {
        impl ParseImage for $ty {
            fn source_type(&self) -> &str {
                &self.source_type
            }
            fn image(&self) -> &str {
                &self.image
            }
        }
    };
}

/*-- Tool argument types ------------------------------------------------------------*/

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
struct ImageSourceArgs {
    #[schemars(
        description = "Image source type: 'file' (path), 'base64' (data), or 'url' (HTTP(S))"
    )]
    source_type: String,
    /// The image: file path, base64-encoded data, or HTTP(S) URL
    image: String,
}
impl_parse_image!(ImageSourceArgs);

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
struct CompareImagesArgs {
    /// Array of image sources to compare (minimum 2)
    images: Vec<ImageSourceArgs>,
    /// Optional free-text instruction
    pub(crate) prompt: Option<String>,
}

#[derive(Debug, serde::Deserialize, schemars::JsonSchema)]
struct AnalyzeArgs {
    #[schemars(description = "Image source type: 'file', 'base64', or 'url'")]
    source_type: String,
    image: String,
    #[schemars(
        description = "Analysis type: 'object-detection', 'text-extraction', 'scene-description', 'ui-analysis', or 'custom'"
    )]
    analysis_type: String,
    /// Optional instruction (required when analysis_type == 'custom')
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(crate) prompt: Option<String>,
}
impl_parse_image!(AnalyzeArgs);

/*-- Tool router (MCP tools) --------------------------------------------------------*/

/// Wraps a VLM backend and exposes it as MCP tools via `#[tool_router]`.
#[derive(Debug, Clone)]
pub(crate) struct VlmToolRegistry {
    vlm: Arc<dyn VlmBackend>,
}

impl VlmToolRegistry {
    pub(crate) fn new(vlm: Arc<dyn VlmBackend>) -> Self {
        Self { vlm }
    }
}

#[tool_router(server_handler)]
impl VlmToolRegistry {
    #[tool(
        description = "Compare two or more images and note differences, similarities, and changes. Pass at least 2 images to compare."
    )]
    async fn vlm_compare_images(
        &self,
        Parameters(args): Parameters<CompareImagesArgs>,
    ) -> Result<String, ErrorData> {
        if args.images.len() < 2 {
            return Err(ErrorData::new(
                ErrorCode::INVALID_PARAMS,
                "compare_images requires at least 2 images".to_string(),
                None,
            ));
        }
        let mut images = Vec::with_capacity(args.images.len());
        for (i, img_arg) in args.images.iter().enumerate() {
            images.push(img_arg.parse_image().map_err(|e| {
                ErrorData::new(
                    ErrorCode::INVALID_PARAMS,
                    format!("Image {}: {}", i + 1, e.message),
                    None,
                )
            })?);
        }
        self.vlm
            .compare_images(images, args.prompt)
            .await
            .map_err(|e| ErrorData::new(ErrorCode::INTERNAL_ERROR, e.to_string(), None))
    }

    #[tool(
        description = "Analyze an image for specific visual characteristics. Use 'object-detection' to list objects, 'text-extraction' for OCR, 'scene-description' for layout/atmosphere, 'ui-analysis' for UI elements, or 'custom' with a prompt for arbitrary analysis."
    )]
    async fn vlm_analyze(
        &self,
        Parameters(args): Parameters<AnalyzeArgs>,
    ) -> Result<String, ErrorData> {
        let image = args.parse_image()?;
        let analysis_type = match args.analysis_type.as_str() {
            "object-detection" => AnalysisType::ObjectDetection,
            "text-extraction" => AnalysisType::TextExtraction,
            "scene-description" => AnalysisType::SceneDescription,
            "ui-analysis" => AnalysisType::UiAnalysis,
            "custom" => {
                let prompt = args.prompt.clone().ok_or_else(|| {
                    ErrorData::new(
                        ErrorCode::INVALID_PARAMS,
                        "'custom' analysis requires a prompt".to_string(),
                        None,
                    )
                })?;
                AnalysisType::Custom(prompt)
            }
            other => {
                return Err(ErrorData::new(
                    ErrorCode::INVALID_PARAMS,
                    format!("Unknown analysis type: '{other}'"),
                    None,
                ));
            }
        };
        self.vlm
            .analyze(image, analysis_type, args.prompt)
            .await
            .map_err(|e| ErrorData::new(ErrorCode::INTERNAL_ERROR, e.to_string(), None))
    }
}
