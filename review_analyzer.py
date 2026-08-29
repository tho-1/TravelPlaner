"""
Review Analyzer & Comparable Rating Engine
==========================================
Standardized Bayesian rating calculator and aspect-level sentiment analyzer
for travel destinations. Follows the defined evaluation rubric:

Aspects:
1. Scenery & atmosphere
2. Things to do
3. Food & drink
4. Value for money
5. Crowds & overtourism
6. Safety & cleanliness
7. Getting around / accessibility

Formula:
- S_aspect per aspect = (pos - neg) / (pos + neutral + neg)
- S_aspect_overall = mean(S_aspect across all 7 aspects) in [-1, 1]
- Platform Bayesian average: R_b = (v * R + m * C) / (v + m)
  where C = 3.5, m = 200, v = review count, R = average rating on [1, 5]
- S_platform = (R_b - 3) / 2 mapped to [-1, 1]
- Final 0-100 Score = round(50 + 50 * (0.6 * S_aspect_overall + 0.4 * S_platform))
- Scaled 0-10 Score = round(Final Score / 10.0, 1)
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Tuple
import pandas as pd


ASPECTS = [
    "Scenery & atmosphere",
    "Things to do",
    "Food & drink",
    "Value for money",
    "Crowds & overtourism",
    "Safety & cleanliness",
    "Getting around / accessibility",
]


@dataclass
class AspectSentiment:
    pos: int = 0
    neutral: int = 0
    neg: int = 0

    @property
    def total(self) -> int:
        return self.pos + self.neutral + self.neg

    @property
    def score(self) -> float:
        """Aspect score in [-1.0, 1.0]. Returns 0.0 if not mentioned."""
        if self.total == 0:
            return 0.0
        return (self.pos - self.neg) / float(self.total)


@dataclass
class PlatformRating:
    source_name: str
    avg_rating: float  # Scale 1.0 - 5.0
    review_count: int  # Total reviews count on platform


@dataclass
class DestinationReviewData:
    destination_name: str
    country: str
    aspect_counts: Dict[str, AspectSentiment] = field(default_factory=dict)
    platform_ratings: List[PlatformRating] = field(default_factory=list)
    total_reviews_analyzed: int = 100
    date_range: str = "Feb 2024 - Feb 2026"
    notes: str = ""

    def calculate_aspect_score(self) -> float:
        """Compute average S_aspect across all 7 aspects."""
        scores = []
        for aspect in ASPECTS:
            sentiment = self.aspect_counts.get(aspect, AspectSentiment())
            scores.append(sentiment.score)
        return sum(scores) / len(scores) if scores else 0.0

    def calculate_platform_score(self, c_prior: float = 3.5, m_weight: float = 200.0) -> float:
        """Compute S_platform mapped to [-1, 1] using Bayesian average."""
        if not self.platform_ratings:
            return 0.0
        
        bayesian_ratings = []
        for p in self.platform_ratings:
            v = float(p.review_count)
            r = float(p.avg_rating)
            # R_b = (v * R + m * C) / (v + m)
            r_b = (v * r + m_weight * c_prior) / (v + m_weight)
            bayesian_ratings.append(r_b)

        avg_r_b = sum(bayesian_ratings) / len(bayesian_ratings)
        # Map [1.0, 5.0] to [-1.0, 1.0] -> (R_b - 3) / 2
        s_platform = (avg_r_b - 3.0) / 2.0
        return max(-1.0, min(1.0, s_platform))

    def calculate_final_scores(self) -> Dict[str, object]:
        """Compute complete score profile."""
        s_aspect = self.calculate_aspect_score()
        s_platform = self.calculate_platform_score()
        
        confidence = "High" if self.total_reviews_analyzed >= 25 else "Low Confidence"
        
        # Final = round(50 + 50 * (0.6 * S_aspect + 0.4 * S_platform))
        combined = 0.6 * s_aspect + 0.4 * s_platform
        score_100 = int(round(50.0 + 50.0 * combined))
        score_100 = max(0, min(100, score_100))
        
        # Scale to 0-10 with 1 decimal place
        score_10 = round(score_100 / 10.0, 1)

        aspect_breakdown = {
            aspect: round(self.aspect_counts.get(aspect, AspectSentiment()).score, 3)
            for aspect in ASPECTS
        }

        return {
            "Destination": self.destination_name,
            "Country": self.country,
            "Final Score (0-100)": score_100,
            "Review Score (0-10)": score_10,
            "S_aspect": round(s_aspect, 3),
            "S_platform": round(s_platform, 3),
            "Total Reviews Analyzed": self.total_reviews_analyzed,
            "Confidence": confidence,
            "Date Range": self.date_range,
            "Aspect Scores": aspect_breakdown,
        }


def compute_destination_ratings(destinations_data: List[DestinationReviewData]) -> pd.DataFrame:
    """Batch compute ratings and return a summary DataFrame."""
    rows = []
    for d in destinations_data:
        res = d.calculate_final_scores()
        row = {
            "Destination": res["Destination"],
            "Country": res["Country"],
            "Score_100": res["Final Score (0-100)"],
            "Rating_10": res["Review Score (0-10)"],
            "S_aspect": res["S_aspect"],
            "S_platform": res["S_platform"],
            "Reviews_Count": res["Total Reviews Analyzed"],
            "Confidence": res["Confidence"],
            "Date_Range": res["Date Range"],
        }
        for aspect, score in res["Aspect Scores"].items():
            row[f"Aspect_{aspect}"] = score
        rows.append(row)
    return pd.DataFrame(rows)
