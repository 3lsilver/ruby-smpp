require 'timeout'
require 'iconv'
require 'scanf'
require 'monitor'
require 'eventmachine'

module Smpp
  class InvalidStateException < Exception; end
    
  class Base < EventMachine::Connection
    include Smpp
    
    # :bound or :unbound
    attr_accessor :state
    
    def Base.logger
      @@logger
    end

    def Base.logger=(logger)
      @@logger = logger
    end

    def logger
      @@logger
    end
    
    def initialize(config)
      @config = config
      @data = ""
    end
    
    # invoked by EventMachine when connected
    def post_init
      # send Bind PDU
      send_bind

      # start timer that will periodically send enquire link PDUs
      start_enquire_link_timer(@config[:enquire_link_delay_secs]) if @config[:enquire_link_delay_secs]
    rescue Exception => ex
      logger.error "Error starting RX: #{ex.message} at #{ex.backtrace[0]}"
    end

    def start_enquire_link_timer(delay_secs)
      logger.info "Starting enquire link timer (with #{delay_secs}s interval)"
      EventMachine::PeriodicTimer.new(delay_secs) do 
        if error?
          logger.warn "Link timer: Connection is in error state. Terminating loop."
          EventMachine::stop_event_loop
        else
          write_pdu Pdu::EnquireLink.new
        end
      end
    end

    # EventMachine::Connection#receive_data
    def receive_data(data)
      #append data to buffer
      @data << data

      while (@data.length >=4)
        cmd_length = @data[0..3].unpack('N').first
        if(@data.length < cmd_length)
          #not complete packet ... break
          break
        end
        
        pkt = @data.slice!(0,cmd_length)

        # parse incoming PDU
        pdu = read_pdu(pkt)

        # let subclass process it
        process_pdu(pdu) if pdu

      end
    end
    
    # EventMachine::Connection#unbind
    def unbind
      logger.warn "EventMachine: unbind invoked in bound state" if @state == :bound
    end
    
    def send_unbind
      #raise rescue logger.debug "Unbinding, now?? #{$!.backtrace[1..5].join("\n")}"
      write_pdu Pdu::Unbind.new
      # leave it to the subclass to process the UnbindResponse
      @state = :unbound
    end

    # process common PDUs
    # returns true if no further processing necessary
    def process_pdu(pdu)      
      case pdu
      when Pdu::EnquireLinkResponse
        # nop
      when Pdu::EnquireLink
        write_pdu(Pdu::EnquireLinkResponse.new(pdu.sequence_number))
      when Pdu::Unbind
        @state = :unbound
        write_pdu(Pdu::UnbindResponse.new(pdu.sequence_number, Pdu::Base::ESME_ROK))
        EventMachine::stop_event_loop
      when Pdu::UnbindResponse      
        logger.info "Unbound OK. Closing connection."
        close_connection
      when Pdu::GenericNack
        logger.warn "Received NACK! (error code #{pdu.error_code})."
        # we don't take this lightly: stop the event loop
        EventMachine::stop_event_loop
      else
        logger.warn "(#{self.class.name}) Received unexpected PDU: #{pdu.to_human}."
        EventMachine::stop_event_loop                
      end
    end
    
    private  
    def write_pdu(pdu)
      logger.debug "<- #{pdu.to_human}"
      hex_debug pdu.data, "<- "
      send_data pdu.data
    end

    def read_pdu(data)
      pdu = nil
      # we may either receive a new request or a response to a previous response.
      begin        
        pdu = Pdu::Base.create(data)
        if !pdu
          logger.warn "Not able to parse PDU!"
        else
          logger.debug "-> " + pdu.to_human          
        end
        hex_debug data, "-> "
      rescue Exception => ex
        logger.error "Exception while reading PDUs: #{ex} in #{ex.backtrace[0]}"
        raise
      end
      pdu
    end

    def hex_debug(data, prefix = "")
      return unless @config[:hex_debug]
      hexdump(data).each_line do |line| 
        logger.debug(prefix + line.chomp)
      end
    end

    def hexdump(target)
      width=16
      group=2

      output = ""
      n=0
      ascii=''
      target.each_byte { |b|
        if n%width == 0
          output << "%s\n%08x: "%[ascii,n]
          ascii='| '
        end
        output << "%02x"%b
        output << ' ' if (n+=1)%group==0
        ascii << "%s"%b.chr.tr('^ -~','.')
      }
      output << ' '*(((2+width-ascii.size)*(2*group+1))/group.to_f).ceil+ascii
      output[1..-1]
    end    
  end
end
