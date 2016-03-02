require 'set'
require 'pp'

class FeatureExtractor
  # returns a Set of features
  def features(string)
    raise "Not implemented."
  end
end

NGram = Struct.new(:ngram, :index)
class NGramBuilder < FeatureExtractor
  SENTINAL_CHAR = "\u00A0"    # non-breaking space

  attr_accessor :n

  def initialize(n)
    self.n = n
  end

  def features(string)
    prefix_and_suffix_string = SENTINAL_CHAR * (n - 1)
    string = prefix_and_suffix_string + string + prefix_and_suffix_string
    ngram_strings = string.each_char.each_cons(n)
    ngram_strings_to_count_map = ngram_strings.reduce({}) {|memo, ngram_string| memo[ngram_string] = (memo[ngram_string] || 0) + 1; memo }
    numbered_ngrams = ngram_strings_to_count_map.flat_map {|ngram_string, count| (1..count).map {|i| NGram.new(ngram_string, i) } }
    numbered_ngrams.to_set
  end
end

class Measure
  # The #min_feature_size and #max_feature_size methods return the lower and upper bounds, respectively, of the range of feature set sizes
  # belonging to the candidate search results.
  # In other words, the only strings in the database that can possibly be considered an approximate search match *must* have a feature set size
  # within the closed interval [min_feature_size(...), max_feature_size(...)]

  # query_size is an int
  # alpha is a double
  def min_feature_size(db, query_size, alpha)
    raise "Not implemented."
  end

  # query_size is an int
  # alpha is a double
  def max_feature_size(db, query_size, alpha)
    raise "Not implemented."
  end

  # This method returns tau, the number of of features that two strings, x and y,
  # must have in common in order for their similarity coefficient to be greater than or equal to alpha.
  # Parameters:
  #   query_size is an int - the number of features in x
  #   y_size is an int - the number of features in y
  #   alpha is a double - the similarity threshold
  def minimum_common_feature_count(query_size, y_size, alpha)
    raise "Not implemented."
  end
end

class CosineMeasure < Measure
  def min_feature_size(db, query_size, alpha)
    (alpha * alpha * query_size).ceil.to_i
  end

  def max_feature_size(db, query_size, alpha)
    (query_size.to_f / (alpha * alpha)).floor.to_i
  end

  def minimum_common_feature_count(query_size, y_size, alpha)
    (alpha * Math.sqrt(query_size * y_size)).ceil.to_i
  end
end

class ExactMeasure < Measure
  def min_feature_size(db, query_size, alpha)
    query_size
  end

  def max_feature_size(db, query_size, alpha)
    query_size
  end

  def minimum_common_feature_count(query_size, y_size, alpha)
    query_size
  end
end

class JaccardMeasure < Measure
  def min_feature_size(db, query_size, alpha)
    (alpha * query_size).ceil.to_i
  end

  def max_feature_size(db, query_size, alpha)
    (query_size.to_f / alpha).floor.to_i
  end

  def minimum_common_feature_count(query_size, y_size, alpha)
    (alpha * (query_size + y_size).to_f / (1 + alpha)).ceil.to_i
  end
end

class OverlapMeasure < Measure
  def min_feature_size(db, query_size, alpha)
    1
  end

  def max_feature_size(db, query_size, alpha)
    db.max_feature_size
  end

  def minimum_common_feature_count(query_size, y_size, alpha)
    (alpha * [query_size, y_size].min).ceil.to_i
  end
end


class Database
  attr_reader :feature_extractor

  def initialize(feature_extractor)
    @strings = Set.new
    @feature_extractor = feature_extractor
    @feature_to_string_map = {}
    @feature_set_size_to_string_map = {}
  end

  def add(string)
    if !@strings.include?(string)
      @strings << string

      features = feature_extractor.features(string)
      feature_set_size = features.size

      # update @feature_set_size_to_string_map
      @feature_set_size_to_string_map[feature_set_size] ||= Set.new
      @feature_set_size_to_string_map[feature_set_size] << string

      # update @feature_to_string_map
      features.each do |feature|
        @feature_to_string_map[feature] ||= Set.new
        @feature_to_string_map[feature] << string
      end
    end
  end

  def min_feature_size
    @feature_set_size_to_string_map.keys.min
  end

  def max_feature_size
    @feature_set_size_to_string_map.keys.max
  end

  def lookup_strings_by_feature_set_size(size)
    @feature_set_size_to_string_map[size] || Set.new
  end

  def lookup_strings_by_feature(feature)
    @feature_to_string_map[feature] || Set.new
  end
end

class StringMatcher
  def initialize(simstring_db, measure)
    @db = simstring_db
    @measure = measure
    @feature_extractor = @db.feature_extractor
  end

  # implements "Algorithm 1: Approximate dictionary matching" described in "Simple and Efficient Algorithm for Approximate Dictionary Matching" (see http://www.aclweb.org/anthology/C10-1096)
  def search(query_string, alpha, measure = @measure)
    feature_set = @feature_extractor.features(query_string)
    feature_set_size = feature_set.size
    matches = []
    min_feature_size_of_matching_string = measure.min_feature_size(@db, feature_set_size, alpha)
    max_feature_size_of_matching_string = measure.max_feature_size(@db, feature_set_size, alpha)
    (min_feature_size_of_matching_string..max_feature_size_of_matching_string).each do |candidate_match_feature_size|
      tau = min_overlap(measure, feature_set_size, candidate_match_feature_size, alpha)
      additional_matches = overlap_join(feature_set, tau, @db, candidate_match_feature_size)
      matches.concat(additional_matches)
    end
    matches
  end

  private

  def min_overlap(measure, query_size, y_size, alpha)
    measure.minimum_common_feature_count(query_size, y_size, alpha)
  end

  # implements "Algorithm 3: CPMerge algorithm" described in "Simple and Efficient Algorithm for Approximate Dictionary Matching" (see http://www.aclweb.org/anthology/C10-1096)
  def overlap_join(query_feature_set, tau, db, y_size)
    query_feature_set_size = query_feature_set.size
    sorted_features = query_feature_set.sort_by {|feature| get(db, y_size, feature).size }
    m = {}
    (0..(query_feature_set_size - tau)).each do |k|
      get(db, y_size, sorted_features[k]).each do |s|
        m[s] ||= 0
        m[s] += 1
      end
    end
    r = []
    ((query_feature_set_size - tau + 1)..(query_feature_set_size - 1)).each do |k|
      candidate_matching_strings = m.keys
      candidate_matching_strings.each do |s|
        m[s] ||= 0
        if get(db, y_size, sorted_features[k]).include?(s)
          m[s] += 1
        end
        if tau <= m[s]
          r << s
          m.delete(s)
        elsif m[s] + (query_feature_set_size - k - 1) < tau
          m.delete(s)
        end
      end
    end
    r
  end

  # Returns a Set of strings that each meet the following 2 criteria:
  # 1. the string has a feature set size equal to <y_size>
  # 2. the string's feature set contains the feature <feature>
  def get(db, y_size, feature)
    db.lookup_strings_by_feature_set_size(y_size) & db.lookup_strings_by_feature(feature)
  end
end


def main
  ngram_builder = NGramBuilder.new(3)
  db = Database.new(ngram_builder)

  db.add("Barack Hussein Obama II")
  db.add("James Gordon Brown")

  matcher = StringMatcher.new(db, CosineMeasure.new)
  puts "1"
  pp matcher.search("Barack Obama", 0.6)
  puts "2"
  pp matcher.search("Gordon Brown", 0.6)
  puts "3"
  pp matcher.search("Obama", 0.4, OverlapMeasure.new)
end

main
