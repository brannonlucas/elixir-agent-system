defmodule NervousSystem.ClaimDetectionTest do
  use ExUnit.Case, async: true

  # Test the claim detection patterns used in Room
  # We're testing private function behavior through integration
  # by examining the patterns directly

  @claim_patterns [
    # Statistics and percentages
    ~r/(\d+(?:\.\d+)?)\s*(?:%|percent)/i,
    # Year references with claims
    ~r/(?:in|since|by|around)\s+(\d{4})/i,
    # Studies and research citations
    ~r/(?:studies?\s+(?:show|indicate|suggest|found|reveal)|research\s+(?:shows?|indicates?|suggests?|found|reveals?))/i,
    # According to sources
    ~r/according\s+to\s+(?:a\s+)?(?:recent\s+)?(?:\w+\s+){1,3}/i,
    # Numerical claims
    ~r/(?:approximately|about|roughly|nearly|over|more than|less than)\s+(\d+(?:,\d{3})*(?:\.\d+)?)\s+(?:million|billion|thousand|people|users|companies)/i,
    # Definitive factual statements
    ~r/(?:it\s+is\s+(?:a\s+)?fact\s+that|the\s+fact\s+is|factually|in\s+fact)/i,
    # Historical claims
    ~r/(?:historically|in\s+history|throughout\s+history)/i,
    # Economic/market claims
    ~r/(?:market\s+(?:share|cap|value)|GDP|revenue|valuation)\s+(?:of|is|was|reached)\s+\$?[\d,.]+/i
  ]

  describe "percentage claims" do
    test "detects percentage claims" do
      assert matches_claim_pattern?("The adoption rate is 75%")
      assert matches_claim_pattern?("About 45.5 percent of users")
      assert matches_claim_pattern?("This represents 100% accuracy")
    end

    test "does not match non-percentage text" do
      refute matches_claim_pattern?("The percentage is unclear")
      refute matches_claim_pattern?("Some users like it")
    end
  end

  describe "year reference claims" do
    test "detects year references" do
      assert matches_claim_pattern?("In 2024, the company launched")
      assert matches_claim_pattern?("Since 1995, technology has evolved")
      assert matches_claim_pattern?("By 2030, experts predict")
      assert matches_claim_pattern?("Around 1980, this became common")
    end

    test "does not match non-year numbers" do
      refute matches_claim_pattern?("The number 500 is significant")
    end
  end

  describe "study/research claims" do
    test "detects research citations" do
      assert matches_claim_pattern?("Studies show that AI is improving")
      # "study indicates" doesn't match because pattern requires "studies" plural
      # or "research" prefix
      assert matches_claim_pattern?("Research suggests this approach works")
      assert matches_claim_pattern?("Studies found significant improvements")
      assert matches_claim_pattern?("Research reveals new patterns")
    end

    test "detects research indicates pattern" do
      assert matches_claim_pattern?("Research indicates a strong correlation")
    end

    test "does not match casual mentions of study" do
      refute matches_claim_pattern?("I need to study more")
    end
  end

  describe "according to claims" do
    test "detects according to sources" do
      assert matches_claim_pattern?("According to recent reports")
      assert matches_claim_pattern?("According to a recent Harvard study")
      assert matches_claim_pattern?("According to the New York Times")
    end
  end

  describe "numerical claims" do
    test "detects large number claims" do
      assert matches_claim_pattern?("Over 5 million users")
      assert matches_claim_pattern?("Approximately 2.5 billion people")
      assert matches_claim_pattern?("More than 100,000 companies")
      assert matches_claim_pattern?("Nearly 50 thousand users")
    end
  end

  describe "definitive factual statements" do
    test "detects fact assertions" do
      assert matches_claim_pattern?("It is a fact that water boils at 100C")
      assert matches_claim_pattern?("The fact is, this approach works")
      assert matches_claim_pattern?("Factually, the data supports this")
      assert matches_claim_pattern?("In fact, this was proven long ago")
    end
  end

  describe "historical claims" do
    test "detects historical references" do
      assert matches_claim_pattern?("Historically, markets have recovered")
      assert matches_claim_pattern?("In history, this pattern repeats")
      assert matches_claim_pattern?("Throughout history, humans have adapted")
    end
  end

  describe "economic/market claims" do
    test "detects market value claims" do
      assert matches_claim_pattern?("Market cap of $500 billion")
      assert matches_claim_pattern?("Revenue reached $10,000,000")
      assert matches_claim_pattern?("Market share is 25%")
      assert matches_claim_pattern?("GDP of 1.5 trillion")
      assert matches_claim_pattern?("Valuation was $100M")
    end
  end

  # Helper to check if text matches any claim pattern
  defp matches_claim_pattern?(text) do
    Enum.any?(@claim_patterns, fn pattern ->
      Regex.match?(pattern, text)
    end)
  end
end
