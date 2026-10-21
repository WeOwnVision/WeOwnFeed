from pydantic import BaseModel, Field
from typing import Optional, List, Dict, Any
from datetime import datetime

class ScrapedArticleIn(BaseModel):
    Site: str
    Baslik: str
    Link: str
    Yazar: Optional[str] = None
    Tarih: Optional[str] = None
    TamMetin: str
    Resim: Optional[str] = None
    image_url: Optional[str] = None
    image_status: Optional[str] = None

class ArticleEnrichmentOut(BaseModel):
    macro_tag: str = Field(..., description="One of: Tech, AI, Hardware, Automotive, Gaming, Finance, Science")
    micro_tags: List[str] = Field(..., description="3 to 6 lowercase specific tags")
    tldr: str = Field(..., description="A 2-sentence summary")

class ArticleTldrOut(BaseModel):
    tldr: str = Field(..., description="A 2-sentence empirical summary of the news.")

class QueryIntentOut(BaseModel):
    macro_tag: Optional[str] = None
    micro_tags: List[str] = Field(default_factory=list)

class ChatTurn(BaseModel):
    role: str
    content: str

class ArticleChatRequest(BaseModel):
    history: List[ChatTurn] = []
    question: str

class CommentCreate(BaseModel):
    user_id: str
    selected_text: Optional[str] = None
    comment_text: str

class UserPreferencesUpdate(BaseModel):
    preferred_macro_tags: List[str] = Field(..., description="List of chosen macro categories")
    preferred_micro_tags: List[str] = Field(default_factory=list, description="List of chosen micro tags")
    interest_context: Optional[str] = Field(
        default=None,
        description="Optional 'why' sentence in any language (max 200 chars). Omit to keep the saved one, '' to clear it."
    )

class FollowCreate(BaseModel):
    name: str = Field(..., description="What to follow, as the user typed it (e.g. 'Revolut')")
    macro: str = Field(..., description="Category the follow belongs to (e.g. 'Finance'); adds context to the search query")

class UserInteractionRequest(BaseModel):
    user_id: str
    interaction_type: str = Field(default="like", description="'like', 'dislike', 'skip', 'bookmark', or 'read'")

class UserProfileOut(BaseModel):
    id: str
    username: str
    avatar_url: Optional[str] = None
    onboarding_completed: bool = False
    preferred_macro_tags: List[str] = Field(default_factory=list)
    preferred_micro_tags: List[str] = Field(default_factory=list)
    interest_context: Optional[str] = None

class DailyDigestOut(BaseModel):
    date: str
    macro_tag: str
    cluster_title: str
    cluster_id: Optional[str] = None
    article_ids: List[str]
    articles: List[Dict[str, Any]] = Field(default_factory=list)
    tavily_sources: List[Dict[str, Any]] = Field(default_factory=list)
    evidence_card: Optional[Dict[str, Any]] = None
    synthesis_report: str
    is_cached: bool = False

class SynthesizeRequest(BaseModel):
    article_ids: List[str]

class DeepResearchRequest(BaseModel):
    query: str = Field(..., min_length=3, description="Investigative topic or claim to research via Tavily")
    model: str = Field(default="mini", description="'mini' or 'pro'")

class SiteWatchTriggerRequest(BaseModel):
    max_extract_per_site: int = Field(default=2, ge=1, le=5)

class SiteFollowRequest(BaseModel):
    url: str = Field(..., description="Root URL of the newsroom / blog / site to follow")

class SiteOut(BaseModel):
    id: str
    url: str
    name: str
    status: str = Field(..., description="'pending', 'mapping', 'crawling', 'ready', 'failed', or 'no_articles'")
    article_count: int = 0
    last_checked_at: Optional[str] = None

