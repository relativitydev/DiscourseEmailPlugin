# name: report-job
# about: Weekly email report for various metrics
# version: 0.0.1
# authors: Garrett Scholtes

enabled_site_setting :weekly_email_report_enabled

RECIPIENTS = [
    "mrobustelli@kcura.com",
    "gscholtes@kcura.com",
    "jsmits@kcura.com"
]
PATH = File.dirname(path)
INTERVAL = 1.week
COMPLIANCE = 3600 * 4 # 4 hours

after_initialize do

    require_dependency 'email/sender'
    require_dependency 'email/message_builder'
    
    class ::WeeklyReportMailer < ::ActionMailer::Base
        default from: SiteSetting.notification_email
    
        def send_report_to(recipient, metrics, time)
            @metrics = metrics
            @hostroot = "#{SiteSetting.scheme}://#{GlobalSetting.hostname}"
            mail(to: recipient, subject: weekly_subject(time)) { |f|
                f.text { render file: File.join(view_path, "send_report_to.text.erb") }
                f.html { render file: File.join(view_path, "send_report_to.html.erb") }
            }
        end
        
        private
        
        def weekly_subject(time)
            "[#{time.to_date}] DevHelp metrics"
        end
        
        def view_path
            File.join(PATH, "app", "views", "weekly_report_mailer")
        end
    end
    
    class ::Jobs::WeeklyReportJob < Jobs::Scheduled
        every INTERVAL
        
        include ActionView::Helpers::DateHelper
        
        def execute(args)
            @latest_midnight = Time.now.midnight
        
            topic_list = new_topics
            metrics = {
                new_topics: topic_list,
                no_response: no_response(topic_list),
                average_response_time: average_response_time(topic_list),
                solved: solved(topic_list),
                top_posters: top_posters(5),
                top_creators: top_topic_creators(5),
                table: gather_category_statistics(topic_list)
            }
            
            RECIPIENTS.each { |recipient|
                WeeklyReportMailer.send_report_to(recipient, metrics, @latest_midnight).deliver_now
            }
        end
        
        private
        
        def new_topics
            Topic.where(created_at: (@latest_midnight - INTERVAL)..@latest_midnight, subtype: nil)
        end
        
        def no_response(topics)
            topics.where(posts_count: (0..1))
        end
        
        def average_response_time(tops, category=nil)
            if category
                topics = tops.where("posts_count > 1").where(category: category)
            else
                topics = tops.where("posts_count > 1")
            end
            avg = 0
            topics_size = topics.size
            if topics_size > 0
                avg = topics.inject(0) { |acc, topic|
                    # Second post is the first reply (first post is the topic itself -- not a reply)
                    post_time = Post.where(topic: topic).order(:created_at)[1].created_at.to_i
                    topic_time = topic.created_at.to_i
                    acc + post_time - topic_time
                } / topics_size
            end 
            distance_of_time_in_words(avg)
        end
        
        def solved(topics)
            TopicCustomField.where(created_at: (@latest_midnight - INTERVAL)..@latest_midnight)
                .where(name: "accepted_answer_post_id")
                .where("topic_id IN (?)", topics.select(:id))
                .size
        end
        
        def top_posters(limit)
            posts = Post.where(created_at: (@latest_midnight - INTERVAL)..@latest_midnight)
            posts.map { |p|
                p.username
            }.each_with_object(Hash.new(0)) { |username, occurrences|
                occurrences[username] += 1
            }.sort_by { |username, count|
                -count
            }.map { |username, count|
                {username: username, posts: count}
            }[0,limit]
        end
        
        def top_topic_creators(limit)
            topics = Topic.where(created_at: (@latest_midnight - INTERVAL)..@latest_midnight)
            topics.map { |t|
                User.find(t.user_id).username
            }.each_with_object(Hash.new(0)) { |username, occurrences|
                occurrences[username] += 1
            }.sort_by { |username, count|
                -count
            }.map { |username, count|
                {username: username, topics: count}
            }[0,limit]
        end
        
        def gather_category_statistics(tops)
            table = []
            Category.select(:id, :name, :slug, :color, :parent_category_id).each { |category|
                parent = nil
                if not category.parent_category_id.nil?
                    parent = Category.find(category.parent_category_id)
                end
                samples = tops.where(category: category)
                response_percent = ""
                percent_compliant = ""
                art = ""
                if samples.length > 0
                    art = average_response_time(tops, category)
                    selected = samples.where("posts_count > 1")
                    response_percent = sprintf("%0.1f %", 100*selected.length.to_f / samples.length)
                    compliant = selected.select { |topic|
                        # Second post is the first reply (first post is the topic itself -- not a reply)
                        post_time = Post.where(topic: topic).order(:created_at)[1].created_at.to_i
                        topic_time = topic.created_at.to_i
                        post_time - topic_time < COMPLIANCE
                    }
                    percent_compliant = compliant.length.to_f / samples.length
                    percent_compliant = sprintf("%0.1f %", 100*percent_compliant)
                end
                table << {
                    category: category,
                    avg_response_time: art,
                    percent_response_compliant: percent_compliant,
                    response_percent: response_percent,
                    sample_size: samples.length,
                    color: category.color,
                    parent: parent
                }
            }
            # Sorts by parent categories, and then by subcategories under each parent
            table.sort_by { |row|
                name = ""
                if row[:parent]
                    name = row[:parent].name.downcase
                end
                name + row[:category].name.downcase
            }
        end
        
    end
    
    # ---------- Send an email immediately when the plugin loads ----------------
    # ---------- otherwise we'll have to wait a week to get a report ------------
    ::Jobs::WeeklyReportJob.new.execute({})
    # ---------------------------------------------------------------------------
    
end