require "./spec_helper"

# Runs `count` jobs of `job_time` each through `dispatcher`, returning the
# elapsed time and the most that ran at once.
private def run_jobs(dispatcher : Arcana::Dispatcher, count : Int32, job_time : Time::Span) : {Time::Span, Int32}
  done = Channel(Nil).new(count)
  mutex = Mutex.new
  running = 0
  peak = 0
  t0 = Time.instant
  count.times do
    dispatcher.submit do
      mutex.synchronize { running += 1; peak = {peak, running}.max }
      sleep job_time
      mutex.synchronize { running -= 1 }
      done.send(nil)
    end
  end
  count.times { done.receive }
  {Time.instant - t0, peak}
end

describe Arcana::Dispatcher do
  it "runs jobs at the same time" do
    elapsed, peak = run_jobs(Arcana::Dispatcher.new(nil), 4, 100.milliseconds)
    peak.should eq(4)
    elapsed.should be < 250.milliseconds
  end

  it "runs at most max_concurrent at once" do
    elapsed, peak = run_jobs(Arcana::Dispatcher.new(2), 6, 100.milliseconds)
    peak.should eq(2)
    elapsed.should be >= 280.milliseconds
  end

  it "reports busy once for overlapping jobs, and idle when the last ends" do
    seen = [] of Bool
    d = Arcana::Dispatcher.new(nil, ->(busy : Bool) { seen << busy; nil })
    run_jobs(d, 3, 50.milliseconds)
    sleep 10.milliseconds
    seen.should eq([true, false])
    d.in_flight.should eq(0)
  end

  it "submit makes the caller wait for a slot; submit_nowait doesn't" do
    d = Arcana::Dispatcher.new(1)
    d.submit { sleep 100.milliseconds }
    t0 = Time.instant
    d.submit { }
    (Time.instant - t0).should be >= 80.milliseconds

    d.submit { sleep 100.milliseconds }
    t0 = Time.instant
    d.submit_nowait { }
    (Time.instant - t0).should be < 20.milliseconds
  end

  it "keeps going after a job raises" do
    d = Arcana::Dispatcher.new(1)
    d.submit { raise "boom" }
    elapsed, _ = run_jobs(d, 1, 1.millisecond)
    elapsed.should be < 1.second
  end

  it "refuses a cap below 1" do
    expect_raises(ArgumentError, /at least 1/) { Arcana::Dispatcher.new(0) }
  end
end
