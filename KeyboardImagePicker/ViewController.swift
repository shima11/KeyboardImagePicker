//
//  ViewController.swift
//  KeyboardImagePicker
//
//  Created by jinsei_shima on 2019/02/09.
//  Copyright © 2019 Jinsei Shima. All rights reserved.
//

import UIKit
import Photos

import RxKeyboard
import RxSwift

class MessageView: UIView {

    override var canBecomeFocused: Bool {
        return true
    }

    private let libraryButton = UIButton(type: .system)
    private let cameraButton = UIButton(type: .system)
    private let textView = UITextView()
    private let sendButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .white

        addSubview(cameraButton)
        addSubview(libraryButton)
        addSubview(textView)
        addSubview(sendButton)

        cameraButton.setImage(UIImage.init(named: "camera"), for: .normal)
        cameraButton.translatesAutoresizingMaskIntoConstraints = false

        libraryButton.setImage(UIImage.init(named: "library"), for: .normal)
        libraryButton.translatesAutoresizingMaskIntoConstraints = false

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = UIFont.systemFont(ofSize: 18, weight: .regular)

        sendButton.setTitle("Send", for: .normal)
        sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 18, weight: .semibold)
        sendButton.translatesAutoresizingMaskIntoConstraints = false


        [
            cameraButton.leftAnchor.constraint(equalTo: leftAnchor, constant: 16),
            cameraButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),

            libraryButton.leftAnchor.constraint(equalTo: cameraButton.rightAnchor, constant: 8.0),
            libraryButton.centerYAnchor.constraint(equalTo: cameraButton.centerYAnchor),

            textView.leftAnchor.constraint(equalTo: libraryButton.rightAnchor, constant: 8),
            textView.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            textView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),

            sendButton.leftAnchor.constraint(equalTo: textView.rightAnchor, constant: 8),
            sendButton.centerYAnchor.constraint(equalTo: cameraButton.centerYAnchor),
            sendButton.rightAnchor.constraint(equalTo: rightAnchor, constant: -16)
            ]
            .forEach { $0.isActive = true }

    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
}

class ViewController: UIViewController {

    private let disposeBag = DisposeBag()

    private let messageInputView = MessageView(frame: .zero)


    @objc func tap() {
        messageInputView.endEditing(false)
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = UIColor.groupTableViewBackground


        view.addSubview(messageInputView)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(tap))
        view.addGestureRecognizer(tapGesture)

        messageInputView.translatesAutoresizingMaskIntoConstraints = false

        [
            messageInputView.leftAnchor.constraint(equalTo: view.leftAnchor, constant: 0),
            messageInputView.rightAnchor.constraint(equalTo: view.rightAnchor, constant: 0),
            messageInputView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 0)
            ]
            .forEach { $0.isActive = true }

        RxKeyboard
            .instance
            .visibleHeight
            .drive(onNext: { [weak self] keyboardVisibleHeight in

                guard let `self` = self else { return }

                if keyboardVisibleHeight <= 0 {
                    self.messageInputView.bottomAnchor.constraint(
                        equalTo: self.view.safeAreaLayoutGuide.bottomAnchor,
                        constant: -keyboardVisibleHeight
                        ).isActive = true
                } else {
                    self.messageInputView.bottomAnchor.constraint(
                        equalTo: self.view.bottomAnchor,
                        constant: -keyboardVisibleHeight
                        ).isActive = true
                }

                self.view.setNeedsLayout()

            })
            .disposed(by: disposeBag)

//        let accessoryView = UIView()
//        accessoryView.backgroundColor = .green
//        accessoryView.frame = .init(x: 0, y: 200, width: 100, height: 60)

//        let inputView = UIView()
//        inputView.backgroundColor = .red
//        inputView.frame = .init(x: 100, y: 100, width: 200, height: 300)

//        messageInputView.inputAccessoryView = accessoryView
//        messageInputView.inputView = inputView

        #warning("inputViewに画像のカルーセル選択画面の追加")


    }


}

