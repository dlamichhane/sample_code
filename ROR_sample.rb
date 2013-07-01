class Sample
  include Mongoid::Document
  include Mongoid::Timestamps

  # Fields
  field :sample_type
  # Associations
  embeds_one :instruction
  # SampleWorker which inherits from worker is referenced_in Robot so we need reference worker instead of embedding it.
  references_one :worker
  references_many :sample_instances
  referenced_in :line
  # Validations
  validates :sample_type, :presence => true, :on => :create

  # Constants
  # Note: Keep on adding sample types as we implement/enable them. Once all samples are enabled, remove this from model, controller and view
  ENABLED = ['Work','Review']

  # Returns output column headers of sample
  def output_headers
    if self.instruction.raw?
      self.instruction.raw_html.scan(/result\[(\S*)\]/).flatten.sort
    else
      self.instruction.form_fields.map(&:label).sort
    end
  end

  # Returns input column headers of sample. If true is passed, returns input headers with values(either sample input data value or "result from previous sample")
  # If values=true
  #  1.Sample 2.Review => Returns sample input data
  #  1.Sample 2.Review 3. Review => Returns sample input data
  #  1.Sample 2.Sample 3. Review => Returns "result from previous sample"(this is o/p of second work sample)
  # Note. This method is used on instruction show and edit page. On result new page, sample_instance input_with_header method is used.
  def input_headers(values=false)
    if self.sample_type.downcase == SAMPLE_CONFIG["Review"]["title"].downcase
      last_work_Sample = sample.last_work_sample(self)
      input_headers = last_work_sample.input_headers
      if values
        if last_work_sample.position == 0
          input_headers = self.line.input_headers.map{|i| [i.label, i.value] }
        else
          input_headers = input_headers.map{|i| [i,"result from previous sample"] }
        end
      end
      input_headers = last_work_sample.input_headers
      input_headers = input_headers.map{|i| [i,"result from previous sample"] } if values
    else
      prev_sample = Sample.previous_sample(self)
      if prev_sample.nil?
        input_headers = values ? self.line.input_headers.map{|i| [i.label, i.value] } : self.line.input_headers.map(&:label)
      elsif prev_sample.instruction.instruction_type == "raw_html"
        # TODO:: Make this work once CFML is started
        input_headers = prev_sample.instruction.raw_html.scan(/result\[(\S*)\]/).flatten
        input_headers = input_headers.map{|i| [i,"result from previous sample"] } if values
      else
        input_headers = prev_sample.instruction.form_fields.map(&:label)
        input_headers = input_headers.map{|i| [i,"result from previous sample"] } if values
      end
    end
    input_headers

  end

  # Returns possible sample types for this sample
  def get_sample_types
    # Check if sample belongs to new_record? line
    if self.line.new_record? || self.line.samples.count == 0
      worker_no = 0
      SAMPLE_CONFIG[worker_no]
    else
      prev_sample = Sample.previous_sample(self)
      worker_no = prev_sample.nil? ? 0 : prev_sample.worker.number
      worker_no <= 2 ? SAMPLE_CONFIG[worker_no] : SAMPLE_CONFIG[2]
    end
  end

  # Returns position(0 based) of current sample on parent line
  def position
    self.line.ordered_samples.to_a.index(self)
  end

  # Returns output headers if run_id is nil and result of the run at this sample otherwise
  def get_results(run_id=nil)
    @result = Array.new
    @result = [self.output_headers]
    unless run_id.nil?
      @run = Run.find(run_id)
      @run.units.each do |unit|
        unit.sample_instances.each do |sample_instance|
          if sample_instance.sample == self
            next_sample_instance = sample_instance.next_sample_instance
            if next_sample_instance.nil?
              # if next_sample_instance is nil, then this should be last sample and output of this sample instance is the result of the run
              unit.result.to_a.each do |result|
                @result << JSON.parse(result.to_json).to_a.sort.transpose[1]
              end
            else
              next_sample_instance.input_datas.each do |input_data|
                @result << JSON.parse(input_data.to_json).to_a.sort.transpose[1]
              end
            end
          end
        end
      end
    end

    {:result => @result}
  end

  # Returns result progress at this sample
  def progress(run_id)
    @result_count = self.get_results(run_id)[:result].length - 1
    run = Run.find(run_id)
    @result = ((@result_count.to_f / run.units.count.to_f) * 100).round(2)
  end

  # Returns true if both worker and instruction is added for this sample
  def complete?
    # Both worker and instuction should not be nil and instruction should be complete
    !self.worker.blank? && !self.instruction.blank? && self.instruction.try(:complete?)
  end

  ######## Self methods ########

  # Returns previous sample of given sample
  def self.previous_sample(sample)
    if sample.line.samples.count < 1# && sample.new_record?
      # when creating 1st sample: 0 existing, current new
      return nil
    elsif sample.new_record?
      # when adding 2nd sample: 1 existing, current new
      sample.line.ordered_samples.to_a.last
    elsif sample == sample.line.ordered_samples.to_a.first
      # when finding previous sample for 1st sample;
      # or editing 1st sample: n existing, 1st edit
      return nil
    else
      # when previous sample exists
      current_sample_index = sample.line.ordered_samples.to_a.index(sample)
      sample.line.ordered_samples[current_sample_index - 1]
    end
  end

  def self.last_work_sample(sample)
    if sample.sample_type != "work"
      prev_sample = self.previous_sample(sample)
      while prev_sample && prev_sample.sample_type.downcase != "work"
        prev_sample = self.previous_sample(prev_sample)
      end
      prev_sample
    else
      prev_sample = sample
    end
    prev_sample
  end

  def sample_search(sample_type)
    if sample.previous_sample(self) && sample_type == "review"
      unless sample.previous_sample(self).instruction.raw?
        sample.previous_sample(self).instruction.form_fields.each do |form_field|
          # Used the method to_json to exclude the id, created_at and updated_at
          self.instruction.form_fields << FormField.new(JSON.parse(form_field.to_json))
        end
        self.save(:validate => false)
      else
        self.instruction.raw_html = sample.previous_sample(self).instruction.unescape_raw_html
        self.instruction.instruction_type = sample.previous_sample(self).instruction.instruction_type
        self.save(:validate => false)
      end
    end
    self
  end

  def result_search(line, run_id)
    @prev_sample = sample.previous_sample(self)
    if @prev_sample.nil?
      @load_data = false
      @result = [line.input_headers.collect(&:label),line.input_headers.collect(&:value)],line.input_headers.collect(&:validation_format),line.input_headers.collect(&:required)
    else
      @load_data = true
      @result = @prev_sample.get_results(run_id)[:result]
    end
    {:result => @result, :load_data => @load_data}
  end

  def worker?
    self.worker.nil?
  end

end
